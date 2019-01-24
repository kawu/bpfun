{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TypeOperators #-}


module Obsolete.RNN3
  ( main
  ) where


import           Prelude hiding (words)

import           GHC.Generics (Generic)
import           GHC.TypeNats (KnownNat)
import qualified GHC.TypeNats as Nats

import           Control.Monad (forM, forM_)

import           System.Random (randomRIO)

-- import           Control.Lens.TH (makeLenses)
import           Lens.Micro.TH (makeLenses)
import           Lens.Micro ((^.))

import           Data.Maybe (fromJust)
import qualified Numeric.Backprop as BP
import           Numeric.Backprop ((^^.))
import qualified Numeric.LinearAlgebra.Static.Backprop as LBP
import           Numeric.LinearAlgebra.Static.Backprop
  (R, L, BVar, Reifies, W, (#))
import qualified Numeric.LinearAlgebra as LAD
import qualified Numeric.LinearAlgebra.Static as LA
import           Numeric.LinearAlgebra.Static.Backprop ((#>))
import qualified Debug.SimpleReflect as Refl

import           Basic
import qualified FeedForward as FFN
import           FeedForward (FFN(..))
import qualified GradientDescent as GD


----------------------------------------------
-- Words
----------------------------------------------


-- | The EOS vector
one, two, three, four, eos :: R 5
one   = LA.vector [1, 0, 0, 0, 0]
two   = LA.vector [0, 1, 0, 0, 0]
three = LA.vector [0, 0, 1, 0, 0]
four  = LA.vector [0, 0, 0, 1, 0]
eos   = LA.vector [0, 0, 0, 0, 1]


----------------------------------------------
-- RNN
----------------------------------------------


-- Recursive Neural Network
data RNN = RNN
  { _ffG :: FFN
      5  -- RNN's hidden state
      5  -- ffG's internal hidden state
      5  -- ffG's output size (size of the vocabulary, including EOS)
  , _ffB :: FFN
      10 -- ffB takes on input the current word + the previous RNN's hidden state
      5  -- ffB's internal hidden state
      5  -- ffB's output size (the next RNN's hidden state)
  , _h0  :: R 5
    -- ^ The initial RNN's hidden state
  }
  deriving (Show, Generic)

instance BP.Backprop RNN

makeLenses ''RNN


runRNN
  :: (Reifies s W)
  => BVar s RNN
  -> [BVar s (R 5)]
    -- ^ Sentence (sequence of vector representations)
  -> BVar s Double
    -- ^ Probability of the sentence (log-domain!)
runRNN net =
  go (net ^^. h0) (log 1.0)
  where
    -- run the calculation, given the previous hidden state
    -- and the list of words to generate
    go hPrev prob (wordVect : ws) =
      let
        -- determine the probability vector
        probVect = softmax $ FFN.run (net ^^. ffG) hPrev
        -- determine the actual probability of the current word
        newProb = log $ probVect `LBP.dot` wordVect
        -- determine the next hidden state
        hNext = FFN.run (net ^^. ffB) (wordVect # hPrev)
      in
        go hNext (prob + newProb) ws
    go hPrev prob [] =
      let
        -- determine the probability vector
        probVect = softmax $ FFN.run (net ^^. ffG) hPrev
        -- determine the actual probability of EOS
        newProb = log $ probVect `LBP.dot` BP.auto eos
      in
        prob + newProb


-- | Substract the second network from the first one.
-- subRNN :: RNN -> RNN -> Double -> RNN
subRNN x y coef = RNN
  { _ffG = FFN.substract (_ffG x) (_ffG y) coef
  , _ffB = FFN.substract (_ffB x) (_ffB y) coef
  , _h0 = _h0 x - scale (_h0 y)
  }
  where
    scale x
      = fromJust
      . LA.create
      . LAD.scale coef
      $ LA.unwrap x


----------------------------------------------
-- Likelihood
----------------------------------------------


-- | Training dataset element
type TrainElem = [R 5]


-- | Training dataset (both good and bad examples)
data Train = Train
  { goodSet :: [TrainElem]
  , badSet :: [TrainElem]
  }


-- | Log-likelihood of the training dataset
logLL
  :: Reifies s W
  => [TrainElem]
  -> BVar s RNN
  -> BVar s Double
logLL dataSet net
  = sum
  . map (runRNN net . map BP.auto)
  $ dataSet


-- | Normalized log-likelihood of the training dataset
normLogLL
  :: Reifies s W
  => [TrainElem]
  -> BVar s RNN
  -> BVar s Double
normLogLL dataSet net =
  sum
    [ logProb / n
    | trainElem <- dataSet
    , let logProb = runRNN net (map BP.auto trainElem)
    , let n = fromIntegral $ length trainElem + 1
    ]


-- | Quality of the network (inverted; the lower the better)
qualityInv
  :: Reifies s W
  => Train
  -> BVar s RNN
  -> BVar s Double
qualityInv Train{..} net =
  negLLL goodSet net - log (1 + negLLL badSet net)
  where
    -- negLLL dataSet net = negate (logLL dataSet net)
    negLLL dataSet net = negate (normLogLL dataSet net)


----------------------------------------------
-- Gradient
----------------------------------------------


-- | Gradient calculation
calcGrad dataSet net =
  BP.gradBP (qualityInv dataSet) net


----------------------------------------------
-- Main
----------------------------------------------


goodData :: [TrainElem]
goodData =
  [ [one]
  , [one, two]
  , [one, two, one]
  , [one, two, one, two]
  -- additional
--   , [one, two, one, two, one]
--   , [one, two, one, two, one, two]
--   , [one, two, one, two, one, two, one]
  , [one, two, one, two, one, two, one, two]
  ]


badData :: [TrainElem]
badData = 
  [ 
    []
--   , [two]
--   , [one, one]
--   , [three]
--   , [four]
--   , [eos]
--   -- additional
--   , [one, three]
--   , [one, four]
--   , [one, eos]
--   , [one, two, three]
--   , [one, two, four]
--   , [one, two, eos]
  ]


-- | Training dataset (both good and bad examples)
trainData = Train
  { goodSet = goodData
  , badSet = badData 
  }


main :: IO ()
main = do
  ffg <- FFN <$> matrix 5 5 <*> vector 5 <*> matrix 5 5 <*> vector 5
  ffb <- FFN <$> matrix 5 10 <*> vector 5 <*> matrix 5 5 <*> vector 5
  rnn <- RNN ffg ffb <$> vector 5
  rnn' <- GD.gradDesc rnn $ GD.Config
    { iterNum = 5000
    , scaleCoef = 0.1
    , gradient = calcGrad trainData
    , substract = subRNN
    , quality = BP.evalBP (qualityInv trainData)
    , reportEvery = 500 }
  let test input = do
        let res = BP.evalBP0 $
              runRNN (BP.auto rnn') (map BP.auto input)
        putStrLn $ show res ++ " (length: " ++ show (length input) ++ ")"
  putStrLn "# good:"
  test [one]
  test [one, two]
  test [one, two, one]
  test [one, two, one, two]
  test [one, two, one, two, one, two]
  test [one, two, one, two, one, two, one, two]
  test [one, two, one, two, one, two, one, two, one, two]
  putStrLn "# bad:"
  test []
  test [two]
  test [one, one]
  test [two, two, two]
  test [one, two, two]
  test [one, one, one]
  test [one, two, one, two, two]
  test [one, two, one, two, one, two, one, two, two, one]


----------------------------------------------
-- Rendering
----------------------------------------------


-- showVect :: (KnownNat n) => R n -> String
-- showVect = undefined