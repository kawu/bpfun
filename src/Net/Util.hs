{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeFamilies #-}


-- | This utility module provides basic artificial network-related functions
-- (activation functions `logistic`, `relu`; initialization functions, etc.).


module Net.Util
  (
  -- * Activation functions
    logistic
  , relu
  , reluSmooth
  , leakyRelu

  -- * Network initialization
  , randomList
  , matrix
  , vector

  -- * Generic transformations
  , scale

  -- * Conversion
  , vec1
  , toList
  , at

  -- * Serialization
  , save
  , load

  -- * Utilities
  , rightInTwo

--   , checkNaN
--   , reportNaN
--   , checkNaNBP
  ) where


import           GHC.TypeNats (KnownNat)

import           System.Random (randomRIO)

import           Control.Lens.At (ix)
import qualified Control.Lens.At as At

import           Data.Maybe (fromJust)
import qualified Data.Vector.Storable.Sized as SVS
import qualified Data.List as List
import           Data.Binary (Binary)
import qualified Data.Binary as Bin
import qualified Data.ByteString.Lazy as BL

import           Codec.Compression.Zlib (compress, decompress)

import qualified Numeric.Backprop as BP
import           Numeric.Backprop (Backprop, BVar, Reifies, W, (^^?))
import           Numeric.LinearAlgebra.Static.Backprop (R, L)
import qualified Numeric.LinearAlgebra as LAD
import qualified Numeric.LinearAlgebra.Static as LA
import qualified Numeric.LinearAlgebra.Static.Vector as LA

-- import           Debug.Trace (trace)


------------------------------------
-- Activation functions
------------------------------------


logistic :: Floating a => a -> a
logistic x = 1 / (1 + exp (-x))


-- -- TODO: are you sure?
-- sigma :: Floating a => a -> a
-- sigma = logistic


reluSmooth :: Floating a => a -> a
reluSmooth x = log(1 + exp(x))


-- | ReLU: Rectifier activation function
relu :: (Floating a) => a -> a
-- NOTE: the selected implementation may seem strange, but it has some
-- advantages: it is "vectorized" and it does not require the `Ord` instance.
relu x = (x + abs x) / 2
-- relu :: (Floating a, Ord a) => a -> a
-- relu x = max 0 x
{-# INLINE relu #-}


-- | Leaky ReLU
leakyRelu :: (Floating a) => a -> a
-- NOTE: the selected implementation works without the `Ord` instance and it is
-- vectorized.
leakyRelu x
  = relu x
  - 0.01 * relu (-x)
{-# INLINE leakyRelu #-}

--  | Correct leaky Relu implementation, somehow yields poor results!
-- leakyRelu :: (Ord a, Floating a) => a -> a
-- leakyRelu x
--   | x < 0 = 0.01*x
--   | otherwise = x
-- {-# INLINE leakyRelu #-}


-- -- | Apply the softmax layer to a vector.
--
-- NOTE: this function is commented out because it cause numerical errors.
--
-- softmax
--   :: (KnownNat n, Reifies s W)
--   => BVar s (R n)
--   -> BVar s (R n)
-- softmax x0 =
--   error "Util.softmax: this function might not be numerically stable!"
-- --   LBP.vmap (/norm) x
-- --   where
-- --     x = LBP.vmap' exp x0
-- --     norm = LBP.norm_1V x


------------------------------------
-- Network initialization
------------------------------------


-- | A random list of very small values (i.e., close to 0).
-- Useful for initialization of a neural networks.
randomList :: Int -> IO [Double]
randomList 0 = return []
randomList n = do
  -- NOTE:  (-0.1, 0.1) worked well, checking smaller values
  -- NOTE:  (-0.01, 0.01) seems to work fine as well
  r  <- randomRIO (-0.01, 0.01)
  rs <- randomList (n-1)
  return (r:rs) 


-- | Create a random matrix
matrix
  :: (KnownNat n, KnownNat m)
  => Int -> Int -> IO (L m n)
matrix n m = do
  list <- randomList (n*m)
  return $ LA.matrix list


-- | Create a random vector
vector :: (KnownNat n) => Int -> IO (R n)
vector k = do
  list <- randomList k
  return $ LA.vector list


------------------------------------
-- Conversion
------------------------------------


-- | Scale the given vector/matrix
scale
  :: (LAD.Linear t d, LA.Sized t c d, LA.Sized t s d) 
  => t -> s -> c
scale coef x = fromJust . LA.create . LAD.scale coef $ LA.unwrap x
{-# INLINE scale #-}


-- | Create a singleton vector (an overkill, but this
-- should be provided in the upstream libraries)
vec1 :: Reifies s W => BVar s Double -> BVar s (R 1)
vec1 =
  BP.isoVar
    (LA.vector . (:[]))
    (\(LA.rVec->v) -> (SVS.index v 0))
{-# INLINE vec1 #-}


-- -- -- | Extract the @0@ (first!) element of the given vector.
-- -- elem0
-- --   :: (Reifies s W, KnownNat n, 1 Nats.<= n)
-- --   => BVar s (R n) -> BVar s Double
-- -- elem0 = fst . LBP.headTail
-- -- {-# INLINE elem0 #-}
-- elem0 = flip at 0
-- {-# INLINE elem0 #-}
-- 
-- 
-- -- -- | Extract the @1@-th (second!) element of the given vector.
-- -- elem1
-- --   :: ( Reifies s W
-- --      , KnownNat (n Nats.- 1), KnownNat n
-- --      , (1 Nats.<=? (n Nats.- 1)) ~ 'True
-- --      , (1 Nats.<=? n) ~ 'True 
-- --      )
-- --   => BVar s (R n) -> BVar s Double
-- -- elem1 = fst . LBP.headTail . snd . LBP.headTail
-- elem1 = flip at 1
-- {-# INLINE elem1 #-}
-- 
-- 
-- -- -- | Extract the @2@ (third!) element of the given vector.
-- -- elem2
-- --   :: ( Reifies s W
-- --      , KnownNat (n Nats.- 1), KnownNat n
-- --      , KnownNat ((n Nats.- 1) Nats.- 1)
-- --      , (1 Nats.<=? ((n Nats.- 1) Nats.- 1)) ~ 'True
-- --      , (1 Nats.<=? (n Nats.- 1)) ~ 'True
-- --      , (1 Nats.<=? n) ~ 'True
-- --      )
-- --   => BVar s (R n) -> BVar s Double
-- -- elem2 = fst . LBP.headTail . snd . LBP.headTail . snd . LBP.headTail
-- elem2 = flip at 2
-- {-# INLINE elem2 #-}


-- | Convert the given vector to a list
toList :: (KnownNat n) => R n -> [Double]
toList = LAD.toList . LA.unwrap


at
  :: ( Num (At.IxValue b), Reifies s W, Backprop b
     , Backprop (At.IxValue b), At.Ixed b
     )
  => BVar s b
  -> At.Index b
  -> BVar s (At.IxValue b)
at v k = maybe 0 id $ v ^^? ix k
{-# INLINE at #-}


----------------------------------------------
-- Serialization
----------------------------------------------


-- | Save the parameters in the given file.
save :: (Binary a) => FilePath -> a -> IO ()
save path =
  BL.writeFile path . compress . Bin.encode


-- | Load the parameters from the given file.
load :: (Binary a) => FilePath -> IO a
load path =
  Bin.decode . decompress <$> BL.readFile path


------------------------------------
-- Utilities
------------------------------------


-- | Split a list x_1, x_2, ..., x_(2n) in two equal parts:
-- 
--   * x_1, x_2, ..., x_n, and
--   * x_(n+1), x_(n+2), ..., x_(2n)
--
rightInTwo :: [a] -> ([a], [a])
rightInTwo xs =
  List.splitAt (length xs `div` 2) xs


-- -- | Make sure that the given number is not a NaN, otherwise raise an error
-- -- with the given string.
-- checkNaNBP :: (Reifies s W) => String -> BVar s Double -> BVar s Double
-- -- checkNaNBP = reportNaN
-- checkNaNBP msg x = BP.isoVar
--   (checkNaN $ msg ++ ".forward")
--   (checkNaN $ msg ++ ".backward")
--   x
-- {-# INLINE checkNaNBP #-}
-- 
-- 
-- -- | Make sure that the given number is not a NaN, otherwise raise an error
-- -- with the given string.
-- reportNaN :: (Reifies s W) => String -> BVar s Double -> BVar s Double
-- reportNaN msg = BP.isoVar
--   (check "forward")
--   (check "backward")
--   where
--     check subMsg x 
--       = trace (msg ++ "." ++ subMsg ++ ": " ++ show x)
--       $ checkNaN ("<<<<" ++ msg ++ "." ++ subMsg ++ " => INFTY! >>>>") x
-- {-# INLINE reportNaN #-}
-- 
-- 
-- -- | Make sure that the given number is not a NaN, otherwise raise an error
-- -- with the given string.
-- checkNaN :: String -> Double -> Double
-- checkNaN msg x
--   | x < infty = x
--   | otherwise = error msg
--   where
--     infty = read "Infinity"
-- {-# INLINE checkNaN #-}
