module Main 
  ( main
  ) where

import           System.Environment (getArgs)

import qualified SMT as SMT
import qualified Net.Ex1 as Ex1
import qualified Net.Ex2 as Ex2
import qualified Net.Ex3 as Ex3
import qualified Net.Ex4 as Ex4
import qualified Net.DAG as DAG
import qualified Net.Graph as Graph
import qualified Net.POS as POS
import qualified GradientDescent.Momentum as Mom
import qualified Embedding.Dict as D

main :: IO ()
main = do
  path : depth : _ <- getArgs
  net <- POS.train path (read depth) =<< POS.new 300 5
  return ()
