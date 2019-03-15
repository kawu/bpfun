{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TypeOperators #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

-- To derive Binary
{-# LANGUAGE DeriveAnyClass #-}


{- Feed-forward network -}


module Net.FeedForward
  ( FFN (..)
  -- , new
  , run
  -- , substract
  ) where

import           GHC.Generics (Generic)
import           GHC.TypeNats (KnownNat)
import qualified GHC.TypeNats as Nats

import           Control.Monad (forM, forM_)
import           Control.DeepSeq (NFData)

import           System.Random (randomRIO)

-- import           Control.Lens.TH (makeLenses)
import           Lens.Micro.TH (makeLenses)
import           Lens.Micro ((^.))

-- import           Data.Proxy (Proxy(..))
import           Data.Binary (Binary)
import           Data.Maybe (fromJust)

import qualified Numeric.Backprop as BP
import           Numeric.Backprop ((^^.))
import qualified Numeric.LinearAlgebra.Static.Backprop as LBP
import           Numeric.LinearAlgebra.Static.Backprop
  (R, L, BVar, Reifies, W, (#))
import qualified Numeric.LinearAlgebra as LAD
import qualified Numeric.LinearAlgebra.Static as LA
import           Numeric.LinearAlgebra.Static.Backprop ((#>))
-- import qualified Debug.SimpleReflect as Refl

import           Numeric.SGD.ParamSet (ParamSet)

import           Net.Basic
import           Net.ArcGraph.Graph (New(..))
-- import qualified GradientDescent.Momentum as Mom


----------------------------------------------
-- Feed-forward net
----------------------------------------------


data FFN idim hdim odim = FFN
  { _nWeights1 :: !(L hdim idim)
  , _nBias1    :: !(R hdim)
  , _nWeights2 :: !(L odim hdim)
  , _nBias2    :: !(R odim)
  }
  deriving (Show, Generic, Binary)

instance (KnownNat idim, KnownNat hdim, KnownNat odim) 
  => BP.Backprop (FFN idim hdim odim)

makeLenses ''FFN

instance (KnownNat i, KnownNat h, KnownNat o)
  => ParamSet (FFN i h o)

instance (KnownNat i, KnownNat h, KnownNat o)
  => NFData (FFN i h o)

instance (KnownNat i, KnownNat h, KnownNat o) => New a b (FFN i h o) where
  new xs ys = FFN
    <$> new xs ys
    <*> new xs ys
    <*> new xs ys
    <*> new xs ys


run
  :: (KnownNat idim, KnownNat hdim, KnownNat odim, Reifies s W)
  => BVar s (FFN idim hdim odim)
  -> BVar s (R idim)
  -> BVar s (R odim)
run net x = z
  where
    -- run first layer
    y = leakyRelu $ (net ^^. nWeights1) #> x + (net ^^. nBias1)
    -- run second layer
    z = (net ^^. nWeights2) #> y + (net ^^. nBias2)


-- -- | Substract the second network from the first one.
-- substract 
--   :: (KnownNat idim, KnownNat hdim, KnownNat odim)
--   => FFN idim hdim odim
--   -> FFN idim hdim odim
--   -> Double 
--   -> FFN idim hdim odim
-- substract x y coef = FFN
--   { _nWeights1 = _nWeights1 x - scale (_nWeights1 y)
--   , _nBias1 = _nBias1 x - scale (_nBias1 y)
--   , _nWeights2 = _nWeights2 x - scale (_nWeights2 y)
--   , _nBias2 = _nBias2 x - scale (_nBias2 y)
--   }
--   where
--     scale x
--       = fromJust
--       . LA.create
--       . LAD.scale coef
--       $ LA.unwrap x
