{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE UnliftedNewtypes #-}

-- | The 'Contiguous' typeclass parameterises over a contiguous array type.
-- It provides the core primitives necessary to implement the common API in "Data.Primitive.Contiguous".
--   This allows us to have a common API to a number of contiguous
--   array types and their mutable counterparts.

module Data.Primitive.Contiguous.Class
  ( Contiguous(..)
  , Slice(..)
  , MutableSlice(..)
  , ContiguousU(..)
  , Always
  ) where


import Data.Primitive.Contiguous.Shim
import Data.Primitive hiding (fromList,fromListN)
import Data.Primitive.Unlifted.Array
import Prelude hiding (length,map,all,any,foldr,foldMap,traverse,read,filter,replicate,null,reverse,foldl,foldr,zip,zipWith,scanl,(<$),elem,maximum,minimum,mapM,mapM_,sequence,sequence_)


import Control.DeepSeq (NFData)
import Control.Monad.Primitive (PrimState, PrimMonad(..))
import Control.Monad.ST (runST,ST)
import Control.Monad.ST.Run (runPrimArrayST,runSmallArrayST,runUnliftedArrayST,runArrayST)
import Data.Kind (Type)
import Data.Primitive.Unlifted.Class (PrimUnlifted)
import GHC.Exts (ArrayArray#,Constraint,sizeofByteArray#,sizeofArray#,sizeofArrayArray#)
import GHC.Exts (SmallMutableArray#,MutableArray#,MutableArrayArray#)
import GHC.Exts (SmallArray#,Array#)
import GHC.Exts (TYPE)

import qualified Control.DeepSeq as DS

-- In GHC 9.2 the UnliftedRep constructor of RuntimeRep was removed
-- and replaced with a type synonym
#if __GLASGOW_HASKELL__  >= 902
import GHC.Exts (UnliftedRep)
#else
import GHC.Exts (RuntimeRep(UnliftedRep))
type UnliftedRep = 'UnliftedRep
#endif


-- | Slices of immutable arrays: packages an offset and length with a backing array.
--
-- @since 0.6.0
data Slice arr a = Slice
  { offset :: {-# UNPACK #-} !Int
  , length :: {-# UNPACK #-} !Int
  , base :: !(Unlifted arr a)
  }

-- | Slices of mutable arrays: packages an offset and length with a mutable backing array.
--
-- @since 0.6.0
data MutableSlice arr s a = MutableSlice
  { offsetMut :: {-# UNPACK #-} !Int
  , lengthMut :: {-# UNPACK #-} !Int
  , baseMut :: !(UnliftedMut arr s a)
  }

-- | The 'Contiguous' typeclass as an interface to a multitude of
-- contiguous structures.
--
-- Some functions do not make sense on slices; for those, see 'ContiguousU'.
class Contiguous (arr :: Type -> Type) where
  -- | The Mutable counterpart to the array.
  type family Mutable arr = (r :: Type -> Type -> Type) | r -> arr
  -- | The constraint needed to store elements in the array.
  type family Element arr :: Type -> Constraint
  -- | The slice type of this array.
  -- The slice of a raw array type @t@ should be 'Slice t',
  -- whereas the slice of a slice should be the same slice type.
  --
  -- @since 0.6.0
  type family Sliced arr :: Type -> Type
  -- | The mutable slice type of this array.
  -- The mutable slice of a raw array type @t@ should be 'MutableSlice t',
  -- whereas the mutable slice of a mutable slice should be the same slice type.
  --
  -- @since 0.6.0
  type family MutableSliced arr :: Type -> Type -> Type


  ------ Construction ------
  -- | Allocate a new mutable array of the given size.
  new :: (PrimMonad m, Element arr b) => Int -> m (Mutable arr (PrimState m) b)
  -- | @'replicateMut' n x@ is a mutable array of length @n@ with @x@ the
  -- value of every element.
  replicateMut :: (PrimMonad m, Element arr b)
    => Int -- length
    -> b -- fill element
    -> m (Mutable arr (PrimState m) b)
  -- | Resize an array without growing it.
  --
  -- @since 0.6.0
  shrink :: (PrimMonad m, Element arr a)
    => Mutable arr (PrimState m) a
    -> Int -- ^ new length
    -> m (Mutable arr (PrimState m) a)
  default shrink ::
       ( ContiguousU arr
       , PrimMonad m, Element arr a)
    => Mutable arr (PrimState m) a -> Int -> m (Mutable arr (PrimState m) a)
  {-# INLINE shrink #-}
  shrink = resize
  -- | The empty array.
  empty :: arr a
  -- | Create a singleton array.
  singleton :: Element arr a => a -> arr a
  -- | Create a doubleton array.
  doubleton :: Element arr a => a -> a -> arr a
  -- | Create a tripleton array.
  tripleton :: Element arr a => a -> a -> a -> arr a
  -- | Create a quadrupleton array.
  quadrupleton :: Element arr a => a -> a -> a -> a -> arr a

  ------ Access and Update ------
  -- | Index into an array at the given index.
  index :: Element arr b => arr b -> Int -> b
  -- | Index into an array at the given index, yielding an unboxed one-tuple of the element.
  index# :: Element arr b => arr b -> Int -> (# b #)
  -- | Indexing in a monad.
  --
  --   The monad allows operations to be strict in the array
  --   when necessary. Suppose array copying is implemented like this:
  --
  --   > copy mv v = ... write mv i (v ! i) ...
  --
  --   For lazy arrays, @v ! i@ would not be not be evaluated,
  --   which means that @mv@ would unnecessarily retain a reference
  --   to @v@ in each element written.
  --
  --   With 'indexM', copying can be implemented like this instead:
  --
  --   > copy mv v = ... do
  --   >   x <- indexM v i
  --   >   write mv i x
  --
  --   Here, no references to @v@ are retained because indexing
  --   (but /not/ the elements) is evaluated eagerly.
  indexM :: (Element arr b, Monad m) => arr b -> Int -> m b
  -- | Read a mutable array at the given index.
  read :: (PrimMonad m, Element arr b)
       => Mutable arr (PrimState m) b -> Int -> m b
  -- | Write to a mutable array at the given index.
  write :: (PrimMonad m, Element arr b)
        => Mutable arr (PrimState m) b -> Int -> b -> m ()

  ------ Properties ------
  -- | Test whether the array is empty.
  null :: arr b -> Bool
  -- | The size of the array
  size :: Element arr b => arr b -> Int
  -- | The size of the mutable array
  sizeMut :: (PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b -> m Int
  -- | Test the two arrays for equality.
  equals :: (Element arr b, Eq b) => arr b -> arr b -> Bool
  -- | Test the two mutable arrays for pointer equality.
  --   Does not check equality of elements.
  equalsMut :: Mutable arr s a -> Mutable arr s a -> Bool

  ------ Conversion ------
  -- | Create a 'Slice' of an array.
  --
  -- @O(1)@.
  --
  -- @since 0.6.0
  slice :: (Element arr a)
    => arr a -- base array
    -> Int -- offset
    -> Int -- length
    -> Sliced arr a
  -- | Create a 'MutableSlice' of a mutable array.
  --
  -- @O(1)@.
  --
  -- @since 0.6.0
  sliceMut :: (Element arr a)
    => Mutable arr s a -- base array
    -> Int -- offset
    -> Int -- length
    -> MutableSliced arr s a
  -- | Create a 'Slice' that covers the entire array.
  --
  -- @since 0.6.0
  toSlice :: (Element arr a) => arr a -> Sliced arr a
  -- | Create a 'MutableSlice' that covers the entire array.
  --
  -- @since 0.6.0
  toSliceMut :: (PrimMonad m, Element arr a)
    => Mutable arr (PrimState m) a
    -> m (MutableSliced arr (PrimState m) a)
  -- | Clone a slice of an array.
  clone :: Element arr b
    => Sliced arr b -- ^ slice to copy
    -> arr b
  default clone ::
       ( Sliced arr ~ Slice arr, ContiguousU arr
       , Element arr b)
    => Sliced arr b -> arr b
  {-# INLINE clone #-}
  clone Slice{offset,length,base} = clone_ (lift base) offset length
  -- | Clone a slice of an array without using the 'Slice' type.
  -- These methods are required to implement 'Contiguous (Slice arr)' for any `Contiguous arr`;
  -- they are not really meant for direct use.
  --
  -- @since 0.6.0
  clone_ :: Element arr a => arr a -> Int -> Int -> arr a
  -- | Clone a slice of a mutable array.
  cloneMut :: (PrimMonad m, Element arr b)
    => MutableSliced arr (PrimState m) b -- ^ Array to copy a slice of
    -> m (Mutable arr (PrimState m) b)
  default cloneMut ::
       ( MutableSliced arr ~ MutableSlice arr, ContiguousU arr
       , PrimMonad m, Element arr b)
    => MutableSliced arr (PrimState m) b -> m (Mutable arr (PrimState m) b)
  {-# INLINE cloneMut #-}
  cloneMut MutableSlice{offsetMut,lengthMut,baseMut}
    = cloneMut_ (liftMut baseMut) offsetMut lengthMut
  -- | Clone a slice of a mutable array without using the 'MutableSlice' type.
  -- These methods are required to implement 'Contiguous (Slice arr)' for any `Contiguous arr`;
  -- they are not really meant for direct use.
  --
  -- @since 0.6.0
  cloneMut_ :: (PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b -- ^ Array to copy a slice of
    -> Int -- ^ offset
    -> Int -- ^ length
    -> m (Mutable arr (PrimState m) b)
  -- | Turn a mutable array slice an immutable array by copying.
  --
  -- @since 0.6.0
  freeze :: (PrimMonad m, Element arr a)
    => MutableSliced arr (PrimState m) a
    -> m (arr a)
  default freeze ::
       ( MutableSliced arr ~ MutableSlice arr, ContiguousU arr
       , PrimMonad m, Element arr a)
    => MutableSliced arr (PrimState m) a -> m (arr a)
  {-# INLINE freeze #-}
  freeze MutableSlice{offsetMut,lengthMut,baseMut}
    = freeze_ (liftMut baseMut) offsetMut lengthMut
  -- | Turn a slice of a mutable array into an immutable one with copying,
  -- without using the 'MutableSlice' type.
  -- These methods are required to implement 'Contiguous (Slice arr)' for any `Contiguous arr`;
  -- they are not really meant for direct use.
  --
  -- @since 0.6.0
  freeze_ :: (PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b
    -> Int -- ^ offset
    -> Int -- ^ length
    -> m (arr b)
  -- | Turn a mutable array into an immutable one without copying.
  --   The mutable array should not be used after this conversion.
  unsafeFreeze :: (PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b
    -> m (arr b)
  unsafeFreeze xs = unsafeShrinkAndFreeze xs =<< sizeMut xs
  {-# INLINE unsafeFreeze #-}
  unsafeShrinkAndFreeze :: (PrimMonad m, Element arr a)
    => Mutable arr (PrimState m) a
    -> Int -- ^ final size
    -> m (arr a)
  default unsafeShrinkAndFreeze ::
       ( ContiguousU arr
       , PrimMonad m, Element arr a)
    => Mutable arr (PrimState m) a -> Int -> m (arr a)
  {-# INLINE unsafeShrinkAndFreeze #-}
  unsafeShrinkAndFreeze arr0 len' =
    resize arr0 len' >>= unsafeFreeze
  -- | Copy a slice of an immutable array into a new mutable array.
  thaw :: (PrimMonad m, Element arr b)
    => Sliced arr b
    -> m (Mutable arr (PrimState m) b)
  default thaw ::
       ( Sliced arr ~ Slice arr, ContiguousU arr
       , PrimMonad m, Element arr b)
    => Sliced arr b
    -> m (Mutable arr (PrimState m) b)
  {-# INLINE thaw #-}
  thaw Slice{offset,length,base} = thaw_ (lift base) offset length
  -- | Copy a slice of an immutable array into a new mutable array without using the 'Slice' type.
  -- These methods are required to implement 'Contiguous (Slice arr)' for any `Contiguous arr`;
  -- they are not really meant for direct use.
  --
  -- @since 0.6.0
  thaw_ :: (PrimMonad m, Element arr b)
    => arr b
    -> Int -- ^ offset into the array
    -> Int -- ^ length of the slice
    -> m (Mutable arr (PrimState m) b)

  ------ Copy Operations ------
  -- | Copy a slice of an array into a mutable array.
  copy :: (PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b -- ^ destination array
    -> Int -- ^ offset into destination array
    -> Sliced arr b -- ^ source slice
    -> m ()
  default copy ::
      ( Sliced arr ~ Slice arr, ContiguousU arr
      , PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b -> Int -> Sliced arr b -> m ()
  {-# INLINE copy #-}
  copy dst dstOff Slice{offset,length,base} = copy_ dst dstOff (lift base) offset length
  -- | Copy a slice of an array into a mutable array without using the 'Slice' type.
  -- These methods are required to implement 'Contiguous (Slice arr)' for any `Contiguous arr`;
  -- they are not really meant for direct use.
  --
  -- @since 0.6.0
  copy_ :: (PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b -- ^ destination array
    -> Int -- ^ offset into destination array
    -> arr b -- ^ source array
    -> Int -- ^ offset into source array
    -> Int -- ^ number of elements to copy
    -> m ()
  -- | Copy a slice of a mutable array into another mutable array.
  --   In the case that the destination and source arrays are the
  --   same, the regions may overlap.
  copyMut :: (PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b -- ^ destination array
    -> Int -- ^ offset into destination array
    -> MutableSliced arr (PrimState m) b -- ^ source slice
    -> m ()
  default copyMut ::
       ( MutableSliced arr ~ MutableSlice arr, ContiguousU arr
       , PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b -> Int -> MutableSliced arr (PrimState m) b -> m ()
  {-# INLINE copyMut #-}
  copyMut dst dstOff MutableSlice{offsetMut,lengthMut,baseMut}
    = copyMut_ dst dstOff (liftMut baseMut) offsetMut lengthMut
  -- | Copy a slice of a mutable array into another mutable array without using the 'Slice' type.
  -- These methods are required to implement 'Contiguous (Slice arr)' for any `Contiguous arr`;
  -- they are not really meant for direct use.
  --
  -- @since 0.6.0
  copyMut_ :: (PrimMonad m, Element arr b)
    => Mutable arr (PrimState m) b -- ^ destination array
    -> Int -- ^ offset into destination array
    -> Mutable arr (PrimState m) b -- ^ source array
    -> Int -- ^ offset into source array
    -> Int -- ^ number of elements to copy
    -> m ()
  -- | Copy a slice of an array and then insert an element into that array.
  --
  -- The default implementation performs a memset which would be unnecessary
  -- except that the garbage collector might trace the uninitialized array.
  --
  -- Was previously @insertSlicing@
  -- @since 0.6.0
  insertAt :: (Element arr b)
    => arr b -- ^ slice to copy from
    -> Int -- ^ index in the output array to insert at
    -> b -- ^ element to insert
    -> arr b
  default insertAt ::
       (Element arr b, ContiguousU arr)
    => arr b -> Int -> b -> arr b
  insertAt src i x = run $ do
    dst <- replicateMut (size src + 1) x
    copy dst 0 (slice src 0 i)
    copy dst (i + 1) (slice src i (size src - i))
    unsafeFreeze dst
  {-# inline insertAt #-}

  ------ Reduction ------
  -- | Reduce the array and all of its elements to WHNF.
  rnf :: (NFData a, Element arr a) => arr a -> ()
  -- | Run an effectful computation that produces an array.
  run :: (forall s. ST s (arr a)) -> arr a

-- | The 'ContiguousU' typeclass is an extension of the 'Contiguous' typeclass,
-- but includes operations that make sense only on uncliced contiguous structures.
--
-- @since 0.6.0
class (Contiguous arr) => ContiguousU arr where
  -- | The unifted version of the immutable array type (i.e. eliminates an indirection through a thunk).
  type Unlifted arr = (r :: Type -> TYPE UnliftedRep) | r -> arr
  -- | The unifted version of the mutable array type (i.e. eliminates an indirection through a thunk).
  type UnliftedMut arr = (r :: Type -> Type -> TYPE UnliftedRep) | r -> arr
  -- | Resize an array into one with the given size.
  resize :: (PrimMonad m, Element arr b)
         => Mutable arr (PrimState m) b
         -> Int
         -> m (Mutable arr (PrimState m) b)
  -- | Unlift an array (i.e. point to the data without an intervening thunk).
  --
  -- @since 0.6.0
  unlift :: arr b -> Unlifted arr b
  -- | Unlift a mutable array (i.e. point to the data without an intervening thunk).
  --
  -- @since 0.6.0
  unliftMut :: Mutable arr s b -> UnliftedMut arr s b
  -- | Lift an array (i.e. point to the data through an intervening thunk).
  --
  -- @since 0.6.0
  lift :: Unlifted arr b -> arr b
  -- | Lift a mutable array (i.e. point to the data through an intervening thunk).
  --
  -- @since 0.6.0
  liftMut :: UnliftedMut arr s b -> Mutable arr s b


-- | A typeclass that is satisfied by all types. This is used
-- used to provide a fake constraint for 'Array' and 'SmallArray'.
class Always a where {}
instance Always a where {}

instance (ContiguousU arr) => Contiguous (Slice arr) where
  type Mutable (Slice arr) = MutableSlice arr
  type Element (Slice arr) = Element arr
  type Sliced (Slice arr) = Slice arr
  type MutableSliced (Slice arr) = MutableSlice arr
  ------ Construction ------
  {-# INLINE new #-}
  new len = do
    baseMut <- new len
    pure MutableSlice{offsetMut=0,lengthMut=len,baseMut=unliftMut baseMut}
  {-# INLINE replicateMut #-}
  replicateMut len x = do
    baseMut <- replicateMut len x
    pure MutableSlice{offsetMut=0,lengthMut=len,baseMut=unliftMut baseMut}
  {-# INLINE shrink #-}
  shrink xs len' = pure $ case compare len' (lengthMut xs) of
    LT -> xs{lengthMut=len'}
    EQ -> xs
    GT -> errorWithoutStackTrace "Data.Primitive.Contiguous.Class.shrink: passed a larger than existing size"
  {-# INLINE empty #-}
  empty = Slice{offset=0,length=0,base=unlift empty}
  {-# INLINE singleton #-}
  singleton a = Slice{offset=0,length=1,base=unlift $ singleton a}
  {-# INLINE doubleton #-}
  doubleton a b = Slice{offset=0,length=2,base=unlift $ doubleton a b}
  {-# INLINE tripleton #-}
  tripleton a b c = Slice{offset=0,length=3,base=unlift $ tripleton a b c}
  {-# INLINE quadrupleton #-}
  quadrupleton a b c d = Slice{offset=0,length=4,base=unlift $ quadrupleton a b c d}

  ------ Access and Update ------
  {-# INLINE index #-}
  index Slice{offset,base} i = index (lift base) (offset + i)
  {-# INLINE index# #-}
  index# Slice{offset,base} i = index# (lift base) (offset + i)
  {-# INLINE indexM #-}
  indexM Slice{offset,base} i = indexM (lift base) (offset + i)
  {-# INLINE read #-}
  read MutableSlice{offsetMut,baseMut} i = read (liftMut baseMut) (offsetMut + i)
  {-# INLINE write #-}
  write MutableSlice{offsetMut,baseMut} i = write (liftMut baseMut) (offsetMut + i)

  ------ Properties ------
  {-# INLINE null #-}
  null Slice{length} = length == 0
  {-# INLINE size #-}
  size Slice{length} = length
  {-# INLINE sizeMut #-}
  sizeMut MutableSlice{lengthMut} = pure lengthMut
  {-# INLINE equals #-}
  equals Slice{offset=oA,length=lenA,base=a}
         Slice{offset=oB,length=lenB,base=b}
    = lenA == lenB && loop 0 oA oB
    where
    loop !i !iA !iB =
      if i == lenA then True
      else index (lift a) iA == index (lift b) iB && loop (i+1) (iA+1) (iB+1)
  {-# INLINE equalsMut #-}
  equalsMut MutableSlice{offsetMut=offA,lengthMut=lenA,baseMut=a}
                MutableSlice{offsetMut=offB,lengthMut=lenB,baseMut=b}
    =  liftMut a `equalsMut` liftMut b
    && offA == offB
    && lenA == lenB

  ------ Conversion ------
  {-# INLINE slice #-}
  slice Slice{offset,base} off' len' = Slice
    { offset = offset + off'
    , length = len'
    , base
    }
  {-# INLINE sliceMut #-}
  sliceMut MutableSlice{offsetMut,baseMut} off' len' = MutableSlice
    { offsetMut = offsetMut + off'
    , lengthMut = len'
    , baseMut
    }
  {-# INLINE clone #-}
  clone = id
  {-# INLINE clone_ #-}
  clone_ Slice{offset,base} off' len' =
    Slice{offset=offset+off',length=len',base}
  {-# INLINE cloneMut #-}
  cloneMut xs@MutableSlice{lengthMut} = cloneMut_ xs 0 lengthMut
  {-# INLINE cloneMut_ #-}
  cloneMut_ MutableSlice{offsetMut,baseMut} off' len' = do
    baseMut' <- cloneMut_ (liftMut baseMut) (offsetMut + off') len'
    pure MutableSlice{offsetMut=0,lengthMut=len',baseMut=unliftMut baseMut'}
  {-# INLINE freeze #-}
  freeze xs@MutableSlice{lengthMut}
    = freeze_ xs 0 lengthMut
  {-# INLINE freeze_ #-}
  freeze_ MutableSlice{offsetMut,baseMut} off' len' = do
    base <- freeze_ (liftMut baseMut) (offsetMut + off') len'
    pure Slice{offset=0,length=len',base=unlift base}
  {-# INLINE unsafeShrinkAndFreeze #-}
  unsafeShrinkAndFreeze MutableSlice{offsetMut=0,lengthMut,baseMut} len' = do
    shrunk <- if lengthMut /= len'
      then resize (liftMut baseMut) len'
      else pure (liftMut baseMut)
    base <- unsafeFreeze shrunk
    pure Slice{offset=0,length=len',base=unlift base}
  unsafeShrinkAndFreeze MutableSlice{offsetMut,baseMut} len' = do
    base <- freeze_ (liftMut baseMut) offsetMut len'
    pure Slice{offset=0,length=len',base=unlift base}
  {-# INLINE thaw #-}
  thaw xs@Slice{length} = thaw_ xs 0 length
  {-# INLINE thaw_ #-}
  thaw_ Slice{offset,base} off' len' = do
    baseMut <- thaw_ (lift base) (offset + off') len'
    pure MutableSlice{offsetMut=0,lengthMut=len',baseMut=unliftMut baseMut}
  {-# INLINE toSlice #-}
  toSlice = id
  {-# INLINE toSliceMut #-}
  toSliceMut = pure

  ------ Copy Operations ------
  {-# INLINE copy #-}
  copy dst dstOff src@Slice{length} = copy_ dst dstOff src 0 length
  {-# INLINE copy_ #-}
  copy_ MutableSlice{offsetMut,baseMut} dstOff Slice{offset,base} off' len =
    copy_ (liftMut baseMut) (offsetMut + dstOff) (lift base) (offset + off') len
  {-# INLINE copyMut #-}
  copyMut dst dstOff src@MutableSlice{lengthMut} = copyMut_ dst dstOff src 0 lengthMut
  {-# INLINE copyMut_ #-}
  copyMut_ MutableSlice{offsetMut=dstOff,baseMut=dst} dstOff'
           MutableSlice{offsetMut=srcOff,baseMut=src} srcOff' len =
    copyMut_ (liftMut dst) (dstOff + dstOff') (liftMut src) (srcOff + srcOff') len
  {-# INLINE insertAt #-}
  insertAt Slice{offset,length,base} i x = run $ do
    dst <- replicateMut (length + 1) x
    copy_ dst 0 (lift base) offset i
    copy_ dst (i + 1) (lift base) (offset + i) (length - i)
    base' <- unsafeFreeze dst
    pure Slice{offset=0,length=length+1,base=unlift base'}

  ------ Reduction ------
  {-# INLINE rnf #-}
  rnf !arr@Slice{length} =
    let go !ix = if ix < length
          then
            let !(# x #) = index# arr ix
             in DS.rnf x `seq` go (ix + 1)
          else ()
     in go 0
  {-# INLINE run #-}
  run = runST


instance Contiguous SmallArray where
  type Mutable SmallArray = SmallMutableArray
  type Element SmallArray = Always
  type Sliced SmallArray = Slice SmallArray
  type MutableSliced SmallArray = MutableSlice SmallArray
  {-# INLINE new #-}
  new n = newSmallArray n errorThunk
  {-# INLINE empty #-}
  empty = mempty
  {-# INLINE index #-}
  index = indexSmallArray
  {-# INLINE indexM #-}
  indexM = indexSmallArrayM
  {-# INLINE index# #-}
  index# = indexSmallArray##
  {-# INLINE read #-}
  read = readSmallArray
  {-# INLINE write #-}
  write = writeSmallArray
  {-# INLINE null #-}
  null a = case sizeofSmallArray a of
    0 -> True
    _ -> False
  {-# INLINE slice #-}
  slice base offset length = Slice{offset,length,base=unlift base}
  {-# INLINE sliceMut #-}
  sliceMut baseMut offsetMut lengthMut = MutableSlice{offsetMut,lengthMut,baseMut=unliftMut baseMut}
  {-# INLINE toSlice #-}
  toSlice base = Slice{offset=0,length=size base,base=unlift base}
  {-# INLINE toSliceMut #-}
  toSliceMut baseMut = do
    lengthMut <- sizeMut baseMut
    pure MutableSlice{offsetMut=0,lengthMut,baseMut=unliftMut baseMut}
  {-# INLINE freeze_ #-}
  freeze_ = freezeSmallArray
  {-# INLINE unsafeFreeze #-}
  unsafeFreeze = unsafeFreezeSmallArray
  {-# INLINE size #-}
  size = sizeofSmallArray
  {-# INLINE sizeMut #-}
  sizeMut = (\x -> pure $! sizeofSmallMutableArray x)
  {-# INLINE thaw_ #-}
  thaw_ = thawSmallArray
  {-# INLINE equals #-}
  equals = (==)
  {-# INLINE equalsMut #-}
  equalsMut = (==)
  {-# INLINE singleton #-}
  singleton a = runST $ do
    marr <- newSmallArray 1 errorThunk
    writeSmallArray marr 0 a
    unsafeFreezeSmallArray marr
  {-# INLINE doubleton #-}
  doubleton a b = runST $ do
    m <- newSmallArray 2 errorThunk
    writeSmallArray m 0 a
    writeSmallArray m 1 b
    unsafeFreezeSmallArray m
  {-# INLINE tripleton #-}
  tripleton a b c = runST $ do
    m <- newSmallArray 3 errorThunk
    writeSmallArray m 0 a
    writeSmallArray m 1 b
    writeSmallArray m 2 c
    unsafeFreezeSmallArray m
  {-# INLINE quadrupleton #-}
  quadrupleton a b c d = runST $ do
    m <- newSmallArray 4 errorThunk
    writeSmallArray m 0 a
    writeSmallArray m 1 b
    writeSmallArray m 2 c
    writeSmallArray m 3 d
    unsafeFreezeSmallArray m
  {-# INLINE rnf #-}
  rnf !ary =
    let !sz = sizeofSmallArray ary
        go !ix = if ix < sz
          then
            let !(# x #) = indexSmallArray## ary ix
             in DS.rnf x `seq` go (ix + 1)
          else ()
     in go 0
  {-# INLINE clone_ #-}
  clone_ = cloneSmallArray
  {-# INLINE cloneMut_ #-}
  cloneMut_ = cloneSmallMutableArray
  {-# INLINE copy_ #-}
  copy_ = copySmallArray
  {-# INLINE copyMut_ #-}
  copyMut_ = copySmallMutableArray
  {-# INLINE replicateMut #-}
  replicateMut = replicateSmallMutableArray
  {-# INLINE run #-}
  run = runSmallArrayST

instance ContiguousU SmallArray where
  type Unlifted SmallArray = SmallArray#
  type UnliftedMut SmallArray = SmallMutableArray#
  {-# INLINE resize #-}
  resize = resizeSmallArray
  {-# INLINE unlift #-}
  unlift (SmallArray x) = x
  {-# INLINE unliftMut #-}
  unliftMut (SmallMutableArray x) = x
  {-# INLINE lift #-}
  lift x = SmallArray x
  {-# INLINE liftMut #-}
  liftMut x = SmallMutableArray x


instance Contiguous PrimArray where
  type Mutable PrimArray = MutablePrimArray
  type Element PrimArray = Prim
  type Sliced PrimArray = Slice PrimArray
  type MutableSliced PrimArray = MutableSlice PrimArray
  {-# INLINE empty #-}
  empty = mempty
  {-# INLINE new #-}
  new = newPrimArray
  {-# INLINE replicateMut #-}
  replicateMut = replicateMutablePrimArray
  {-# INLINE index #-}
  index = indexPrimArray
  {-# INLINE index# #-}
  index# arr ix = (# indexPrimArray arr ix #)
  {-# INLINE indexM #-}
  indexM arr ix = pure (indexPrimArray arr ix)
  {-# INLINE read #-}
  read = readPrimArray
  {-# INLINE write #-}
  write = writePrimArray
  {-# INLINE size #-}
  size = sizeofPrimArray
  {-# INLINE sizeMut #-}
  sizeMut = getSizeofMutablePrimArray
  {-# INLINE slice #-}
  slice base offset length = Slice{offset,length,base=unlift base}
  {-# INLINE sliceMut #-}
  sliceMut baseMut offsetMut lengthMut = MutableSlice{offsetMut,lengthMut,baseMut=unliftMut baseMut}
  {-# INLINE toSlice #-}
  toSlice base = Slice{offset=0,length=size base,base=unlift base}
  {-# INLINE toSliceMut #-}
  toSliceMut baseMut = do
    lengthMut <- sizeMut baseMut
    pure MutableSlice{offsetMut=0,lengthMut,baseMut=unliftMut baseMut}
  {-# INLINE freeze_ #-}
  freeze_ = freezePrimArrayShim
  {-# INLINE unsafeFreeze #-}
  unsafeFreeze = unsafeFreezePrimArray
  {-# INLINE thaw_ #-}
  thaw_ = thawPrimArray
  {-# INLINE copy_ #-}
  copy_ = copyPrimArray
  {-# INLINE copyMut_ #-}
  copyMut_ = copyMutablePrimArray
  {-# INLINE clone_ #-}
  clone_ = clonePrimArrayShim
  {-# INLINE cloneMut_ #-}
  cloneMut_ = cloneMutablePrimArrayShim
  {-# INLINE equals #-}
  equals = (==)
  {-# INLINE null #-}
  null (PrimArray a) = case sizeofByteArray# a of
    0# -> True
    _ -> False
  {-# INLINE equalsMut #-}
  equalsMut = sameMutablePrimArray
  {-# INLINE rnf #-}
  rnf (PrimArray !_) = ()
  {-# INLINE singleton #-}
  singleton a = runPrimArrayST $ do
    marr <- newPrimArray 1
    writePrimArray marr 0 a
    unsafeFreezePrimArray marr
  {-# INLINE doubleton #-}
  doubleton a b = runPrimArrayST $ do
    m <- newPrimArray 2
    writePrimArray m 0 a
    writePrimArray m 1 b
    unsafeFreezePrimArray m
  {-# INLINE tripleton #-}
  tripleton a b c = runPrimArrayST $ do
    m <- newPrimArray 3
    writePrimArray m 0 a
    writePrimArray m 1 b
    writePrimArray m 2 c
    unsafeFreezePrimArray m
  {-# INLINE quadrupleton #-}
  quadrupleton a b c d = runPrimArrayST $ do
    m <- newPrimArray 4
    writePrimArray m 0 a
    writePrimArray m 1 b
    writePrimArray m 2 c
    writePrimArray m 3 d
    unsafeFreezePrimArray m
  {-# INLINE insertAt #-}
  insertAt src i x = runPrimArrayST $ do
    dst <- new (size src + 1)
    copy dst 0 (slice src 0 i)
    write dst i x
    copy dst (i + 1) (slice src i (size src - i))
    unsafeFreeze dst
  {-# INLINE run #-}
  run = runPrimArrayST

newtype PrimArray# a = PrimArray# ByteArray#
newtype MutablePrimArray# s a = MutablePrimArray# (MutableByteArray# s)
instance ContiguousU PrimArray where
  type Unlifted PrimArray = PrimArray#
  type UnliftedMut PrimArray = MutablePrimArray#
  {-# INLINE resize #-}
  resize = resizeMutablePrimArray
  {-# INLINE unlift #-}
  unlift (PrimArray x) = PrimArray# x
  {-# INLINE unliftMut #-}
  unliftMut (MutablePrimArray x) = MutablePrimArray# x
  {-# INLINE lift #-}
  lift (PrimArray# x) = PrimArray x
  {-# INLINE liftMut #-}
  liftMut (MutablePrimArray# x) = MutablePrimArray x


instance Contiguous Array where
  type Mutable Array = MutableArray
  type Element Array = Always
  type Sliced Array = Slice Array
  type MutableSliced Array = MutableSlice Array
  {-# INLINE empty #-}
  empty = mempty
  {-# INLINE new #-}
  new n = newArray n errorThunk
  {-# INLINE replicateMut #-}
  replicateMut = newArray
  {-# INLINE index #-}
  index = indexArray
  {-# INLINE index# #-}
  index# = indexArray##
  {-# INLINE indexM #-}
  indexM = indexArrayM
  {-# INLINE read #-}
  read = readArray
  {-# INLINE write #-}
  write = writeArray
  {-# INLINE size #-}
  size = sizeofArray
  {-# INLINE sizeMut #-}
  sizeMut = (\x -> pure $! sizeofMutableArray x)
  {-# INLINE slice #-}
  slice base offset length = Slice{offset,length,base=unlift base}
  {-# INLINE sliceMut #-}
  sliceMut baseMut offsetMut lengthMut = MutableSlice{offsetMut,lengthMut,baseMut=unliftMut baseMut}
  {-# INLINE toSlice #-}
  toSlice base = Slice{offset=0,length=size base,base=unlift base}
  {-# INLINE toSliceMut #-}
  toSliceMut baseMut = do
    lengthMut <- sizeMut baseMut
    pure MutableSlice{offsetMut=0,lengthMut,baseMut=unliftMut baseMut}
  {-# INLINE freeze_ #-}
  freeze_ = freezeArray
  {-# INLINE unsafeFreeze #-}
  unsafeFreeze = unsafeFreezeArray
  {-# INLINE thaw_ #-}
  thaw_ = thawArray
  {-# INLINE copy_ #-}
  copy_ = copyArray
  {-# INLINE copyMut_ #-}
  copyMut_ = copyMutableArray
  {-# INLINE clone #-}
  clone Slice{offset,length,base} = clone_ (lift base) offset length
  {-# INLINE clone_ #-}
  clone_ = cloneArray
  {-# INLINE cloneMut_ #-}
  cloneMut_ = cloneMutableArray
  {-# INLINE equals #-}
  equals = (==)
  {-# INLINE null #-}
  null (Array a) = case sizeofArray# a of
    0# -> True
    _ -> False
  {-# INLINE equalsMut #-}
  equalsMut = sameMutableArray
  {-# INLINE rnf #-}
  rnf !ary =
    let !sz = sizeofArray ary
        go !i
          | i == sz = ()
          | otherwise =
              let !(# x #) = indexArray## ary i
               in DS.rnf x `seq` go (i+1)
     in go 0
  {-# INLINE singleton #-}
  singleton a = runArrayST (newArray 1 a >>= unsafeFreezeArray)
  {-# INLINE doubleton #-}
  doubleton a b = runArrayST $ do
    m <- newArray 2 a
    writeArray m 1 b
    unsafeFreezeArray m
  {-# INLINE tripleton #-}
  tripleton a b c = runArrayST $ do
    m <- newArray 3 a
    writeArray m 1 b
    writeArray m 2 c
    unsafeFreezeArray m
  {-# INLINE quadrupleton #-}
  quadrupleton a b c d = runArrayST $ do
    m <- newArray 4 a
    writeArray m 1 b
    writeArray m 2 c
    writeArray m 3 d
    unsafeFreezeArray m
  {-# INLINE run #-}
  run = runArrayST

instance ContiguousU Array where
  type Unlifted Array = Array#
  type UnliftedMut Array = MutableArray#
  {-# INLINE resize #-}
  resize = resizeArray
  {-# INLINE unlift #-}
  unlift (Array x) = x
  {-# INLINE unliftMut #-}
  unliftMut (MutableArray x) = x
  {-# INLINE lift #-}
  lift x = Array x
  {-# INLINE liftMut #-}
  liftMut x = MutableArray x


instance Contiguous UnliftedArray where
  type Mutable UnliftedArray = MutableUnliftedArray
  type Element UnliftedArray = PrimUnlifted
  type Sliced UnliftedArray = Slice UnliftedArray
  type MutableSliced UnliftedArray = MutableSlice UnliftedArray
  {-# INLINE empty #-}
  empty = emptyUnliftedArray
  {-# INLINE new #-}
  new = unsafeNewUnliftedArray
  {-# INLINE replicateMut #-}
  replicateMut = newUnliftedArray
  {-# INLINE index #-}
  index = indexUnliftedArray
  {-# INLINE index# #-}
  index# arr ix = (# indexUnliftedArray arr ix #)
  {-# INLINE indexM #-}
  indexM arr ix = pure (indexUnliftedArray arr ix)
  {-# INLINE read #-}
  read = readUnliftedArray
  {-# INLINE write #-}
  write = writeUnliftedArray
  {-# INLINE size #-}
  size = sizeofUnliftedArray
  {-# INLINE sizeMut #-}
  sizeMut = pure . sizeofMutableUnliftedArray
  {-# INLINE slice #-}
  slice base offset length = Slice{offset,length,base=unlift base}
  {-# INLINE sliceMut #-}
  sliceMut baseMut offsetMut lengthMut = MutableSlice{offsetMut,lengthMut,baseMut=unliftMut baseMut}
  {-# INLINE freeze_ #-}
  freeze_ = freezeUnliftedArray
  {-# INLINE unsafeFreeze #-}
  unsafeFreeze = unsafeFreezeUnliftedArray
  {-# INLINE toSlice #-}
  toSlice base = Slice{offset=0,length=size base,base=unlift base}
  {-# INLINE toSliceMut #-}
  toSliceMut baseMut = do
    lengthMut <- sizeMut baseMut
    pure MutableSlice{offsetMut=0,lengthMut,baseMut=unliftMut baseMut}
  {-# INLINE thaw_ #-}
  thaw_ = thawUnliftedArray
  {-# INLINE copy_ #-}
  copy_ = copyUnliftedArray
  {-# INLINE copyMut_ #-}
  copyMut_ = copyMutableUnliftedArray
  {-# INLINE clone_ #-}
  clone_ = cloneUnliftedArray
  {-# INLINE cloneMut_ #-}
  cloneMut_ = cloneMutableUnliftedArray
  {-# INLINE equals #-}
  equals = (==)
  {-# INLINE null #-}
  null (UnliftedArray a) = case sizeofArrayArray# a of
    0# -> True
    _ -> False
  {-# INLINE equalsMut #-}
  equalsMut = sameMutableUnliftedArray
  {-# INLINE rnf #-}
  rnf !ary =
    let !sz = sizeofUnliftedArray ary
        go !i
          | i == sz = ()
          | otherwise =
              let x = indexUnliftedArray ary i
               in DS.rnf x `seq` go (i+1)
     in go 0
  {-# INLINE singleton #-}
  singleton a = runUnliftedArrayST (newUnliftedArray 1 a >>= unsafeFreezeUnliftedArray)
  {-# INLINE doubleton #-}
  doubleton a b = runUnliftedArrayST $ do
    m <- newUnliftedArray 2 a
    writeUnliftedArray m 1 b
    unsafeFreezeUnliftedArray m
  {-# INLINE tripleton #-}
  tripleton a b c = runUnliftedArrayST $ do
    m <- newUnliftedArray 3 a
    writeUnliftedArray m 1 b
    writeUnliftedArray m 2 c
    unsafeFreezeUnliftedArray m
  {-# INLINE quadrupleton #-}
  quadrupleton a b c d = runUnliftedArrayST $ do
    m <- newUnliftedArray 4 a
    writeUnliftedArray m 1 b
    writeUnliftedArray m 2 c
    writeUnliftedArray m 3 d
    unsafeFreezeUnliftedArray m
  {-# INLINE run #-}
  run = runUnliftedArrayST

newtype UnliftedArray# a = UnliftedArray# ArrayArray#
newtype MutableUnliftedArray# s a = MutableUnliftedArray# (MutableArrayArray# s)
instance ContiguousU UnliftedArray where
  type Unlifted UnliftedArray = UnliftedArray#
  type UnliftedMut UnliftedArray = MutableUnliftedArray#
  {-# INLINE resize #-}
  resize = resizeUnliftedArray
  {-# INLINE unlift #-}
  unlift (UnliftedArray x) = (UnliftedArray# x)
  {-# INLINE unliftMut #-}
  unliftMut (MutableUnliftedArray x) = (MutableUnliftedArray# x)
  {-# INLINE lift #-}
  lift (UnliftedArray# x) = UnliftedArray x
  {-# INLINE liftMut #-}
  liftMut (MutableUnliftedArray# x) = MutableUnliftedArray x
