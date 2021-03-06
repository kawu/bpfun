{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}


-- | Support for the Cupt format -- see
-- http://multiword.sourceforge.net/PHITE.php?sitesig=CONF&page=CONF_04_LAW-MWE-CxG_2018&subpage=CONF_45_Format_specification.


module Format.Cupt
  (
    -- * Types
    GenSent
  , GenToken (..)
  , MaySent
  , MayToken
  , Sent
  , Token
  , TokID (..)
  , MweID
  , MweTyp
  , Mwe (..)
  , chosen
  , retrieveMWEs

    -- * Parsing
  , readCupt
  , parseCupt
  , parsePar

    -- * Rendering
  , writeCupt
  , renderCupt
  , renderPar

    -- * Conversion
  , decorate
  , preserveOnly
  , abstract

    -- * Merging
  , mergeCupt

    -- * Cleanup
  , removeMweAnnotations
  ) where


import           GHC.Generics (Generic)

import           Control.DeepSeq (NFData)

import           Data.Binary (Binary)
-- import qualified Data.Binary as Bin
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import qualified Data.List as List
import qualified Data.Text.Lazy as L
import qualified Data.Text.Lazy.IO as L
import qualified Data.Text as T
-- import qualified Data.ByteString.Lazy as B
-- import           Codec.Compression.Zlib (compress, decompress)


-----------------------------------
-- Types
-----------------------------------


-- | Concrete types.
type MaySent = GenSent (Maybe MweTyp)
type MayToken = GenToken (Maybe MweTyp)
type Sent = GenSent MweTyp
type Token = GenToken MweTyp


-- | A Cupt element, i.e., a dependency tree with MWE annotations
type GenSent mwe = [GenToken mwe]


-- | See description of the CoNLL-U format: http://universaldependencies.org/format.html
data GenToken mwe = Token
  { tokID :: TokID
    -- ^ Word index, integer starting at 1 for each new sentence; may be a range
    -- for multiword tokens; may be a decimal number for empty nodes.
  , orth :: T.Text
    -- ^ Orthographic form
  , lemma :: T.Text
  , upos :: T.Text
    -- ^ Universal POS
  , xpos :: T.Text
    -- ^ Language-specific POS
  , feats :: M.Map T.Text T.Text
    -- ^ List of morphological features from the universal feature inventory or from a defined language-specific extension; underscore if not available.
  , dephead :: TokID
    -- ^ Head of the current word, which is either a value of ID or zero [0].
  , deprel :: T.Text
    -- ^ Universal dependency relation to the HEAD (root iff HEAD = 0) or a defined language-specific subtype of one.
  , deps :: T.Text
    -- ^ Enhanced dependency graph in the form of a list of head-deprel pairs.
  , misc :: T.Text
    -- ^ Any other annotation. It does not seem to be used in Cupt, though?
  -- mwe :: [(MweID, Maybe MweTyp)]
  , mwe :: [(MweID, mwe)]
    -- ^ MWE-related annotation. It might be a list, i.e., the token can be a
    -- part of several MWEs. Note that only the first occurrence of an MWE is
    -- supplied with the `MweTyp`e.
  } deriving (Show, Eq, Ord, Generic, Binary, NFData)


-- | Word index, integer starting at 1 for each new sentence; may be a range for
-- multiword tokens.
--
-- WARNING: we use `TokIDRange 0 0` as a special value for tokens out of the
-- selected tokenization (basically it stands for '_').
data TokID
  = TokID Int
  | TokIDRange Int Int
  -- | TokIDCopy Int Int
  --   -- ^ An empty node (marked as `CopyOf` in UD data)
  -- NOTE: `TokIDCopy` was commented out because it is very rare and makes data
  -- processing much harder at the same time.
  deriving (Show, Eq, Ord, Generic, Binary, NFData)


-- | Sentence-local MWE ID.
type MweID = Int


-- | MWE type.
type MweTyp = T.Text


-- | MWE annotation
data Mwe = Mwe
  { mweTyp' :: MweTyp
  , mweToks :: S.Set Token
  } deriving (Show, Eq, Ord)

instance Semigroup Mwe where
  Mwe t1 s1 <> Mwe t2 s2
    | t1 == t2 = Mwe t1 (S.union s1 s2)
    | otherwise = error
        "Cupt.Mwe.<>: multi-type MWE?"


-- | Retrieve the set of multiword expressions in the given sentence.
retrieveMWEs :: Sent -> M.Map MweID Mwe
retrieveMWEs =
  List.foldl' update M.empty
  where
    update m0 tok =
      List.foldl' updateOne m0 (mwe tok)
      where
        tokSng = S.singleton tok
        updateOne m (mweId, mweTyp) =
          M.insertWith (<>) mweId (Mwe mweTyp tokSng) m


-----------------------------------
-- Parsing
-----------------------------------


-- | Is the token in the chosen segmentation?
chosen :: GenToken mwe -> Bool
chosen tok = upos tok /= "_"


-- | Read an entire Cupt file.
readCupt :: FilePath -> IO [[MaySent]]
readCupt = fmap parseCupt . L.readFile


-- | Parse an entire Cupt file.
parseCupt :: L.Text -> [[MaySent]]
parseCupt
  = map parsePar
  . filter (not . L.null)
  . L.splitOn "\n\n"


-- | Parse a given textual representation of a paragraph. It can be assumed to
-- contain no empty lines, but it can contain comments. Moreover, it can contain
-- several sentences, each starting with token ID == 1.
parsePar :: L.Text -> [MaySent]
parsePar
  = groupBy tokLE
  . map (parseToken . L.toStrict)
  . filter (not . L.isPrefixOf "#")
  . L.lines
  where
    tokLE tx ty = fstPos (tokID tx) <= fstPos (tokID ty)
    fstPos (TokID x) = x
    fstPos (TokIDRange x _) = x
    -- fstPos (TokIDCopy x _) = x
    -- tokDiff tx ty = tokID tx /= tokID ty


parseToken :: T.Text -> MayToken
parseToken line =
  case T.splitOn "\t" line of
    [id', orth', lemma', upos', xpos', feats', head', deprel', deps', misc', mwe'] -> Token
      { tokID = parseTokID id'
      , orth = orth'
      , lemma = lemma'
      , upos = upos'
      , xpos = xpos'
      , feats = parseFeats feats'
      , dephead = parseTokID head'
      , deprel = deprel'
      , deps = deps'
      , misc = misc'
      , mwe = parseMWE mwe'
      }
    _ -> error "Cupt.parseToken: incorrenct number of line elements"


-- | NOTE: We treat "-" as root ID, for the lack of a better solution (SL).
parseTokID :: T.Text -> TokID
parseTokID "_" = TokIDRange 0 0
parseTokID "-" = TokID 0
parseTokID txt
  | T.isInfixOf "-" txt =
      case map (read . T.unpack) . T.split (=='-') $ txt of
        [x, y] -> TokIDRange x y
        _ -> error "Cupt.parseTokID: invalid token ID with -"
  | T.isInfixOf "." txt = error
      -- case map (read . T.unpack) . T.split (=='.') $ txt of
      --   [x, y] -> TokIDCopy x y
      --   _ -> error "Cupt.parseTokID: invalid token ID with ."
      "Cupt.parseTokID: invalid token ID with . (token copies not supported!)"
  | otherwise =
      TokID $ read (T.unpack txt)


parseFeats :: T.Text -> M.Map T.Text T.Text
parseFeats txt =
  case txt of
    "_" -> M.empty
    _ -> M.fromList
      . map toPair
      . map (T.splitOn "=")
      . T.splitOn "|"
      $ txt
  where
    toPair [x, y] = (x, y)
    toPair [x] = (x, "")
    toPair _ = error "Cupt.parseFeats.toPair: not a pair!"


parseMWE :: T.Text -> [(MweID, Maybe MweTyp)]
parseMWE txt =
  case txt of
    "*" -> [] -- no MWE
    "_" -> [] -- underspecified, we represent it by [] too
    _ -> map parseOneMWE . T.splitOn ";" $ txt
  where
    parseOneMWE x =
      case T.splitOn ":" x of
        [mid] -> (read $ T.unpack mid, Nothing)
        [mid, mty] -> (read $ T.unpack mid, Just mty)
        _ -> error "Cupt.parseMWE: ???"


-----------------------------------
-- Rendering
-----------------------------------


writeCupt :: [[MaySent]] -> FilePath -> IO ()
writeCupt xs filePath = L.writeFile filePath (renderCupt xs)


renderCupt :: [[MaySent]] -> L.Text
renderCupt = L.intercalate "\n" . map renderPar


renderPar :: [MaySent] -> L.Text
renderPar = L.unlines . map renderToken . concat


renderToken :: MayToken -> L.Text
renderToken Token{..} =
  L.intercalate "\t"
  [ renderTokID tokID
  , L.fromStrict orth
  , L.fromStrict lemma
  , L.fromStrict upos
  , L.fromStrict xpos
  , renderFeats feats
  , renderTokID dephead
  , L.fromStrict deprel
  , L.fromStrict deps
  , L.fromStrict misc
  , renderMWE mwe
  ]


renderTokID :: TokID -> L.Text
renderTokID tid =
  case tid of
    TokID x ->
      psh x
    TokIDRange 0 0 ->
      "_"
    TokIDRange x y ->
      L.intercalate "-" [psh x, psh y]
    -- TokIDCopy x y ->
    --   L.intercalate "." [psh x, psh y]
  where
    psh = L.pack . show


renderFeats :: M.Map T.Text T.Text -> L.Text
renderFeats featMap
  | M.null featMap = "_"
  | otherwise = L.intercalate "|" . map renderPair $ M.toList featMap
  where
    renderPair (att, val) = L.concat
      [ L.fromStrict att
      , "="
      , L.fromStrict val
      ]


renderMWE :: [(MweID, Maybe MweTyp)] -> L.Text
renderMWE xs
  | null xs = "*"
  | otherwise = L.intercalate ";" . map renderMwePart $ xs
  where
    renderMwePart (mweID, mayTyp) =
      case mayTyp of
        Nothing -> renderMweID mweID
        Just tp -> L.intercalate ":"
          [ renderMweID mweID
          , L.fromStrict tp ]
    renderMweID = L.pack . show


-----------------------------------
-- Conversion
-----------------------------------


-- -- | An artificial root token.
-- root :: Token
-- root = Token
--   { tokID = TokID 0
--   , orth = ""
--   , lemma = ""
--   , upos = ""
--   , xpos = ""
--   , feats = M.empty
--   , dephead = rootParID
--   , deprel = ""
--   , deps = ""
--   , misc = ""
--   , mwe = []
--   }


-- -- | ID to refer to the parent of the artificial root node.
-- rootParID :: TokID
-- rootParID = TokID (-1)


-- | Decorate all MWE instances with their types.
decorate :: MaySent -> Sent
decorate =
  -- (root:) .
  snd . List.mapAccumL update M.empty
  where
    update typMap tok =
      let (typMap', mwe') = List.mapAccumL updateOne typMap (mwe tok)
      in  (typMap', tok {mwe=mwe'})
    updateOne typMap (mweID, mweTyp) =
      case mweTyp of
        Nothing  -> (typMap, (mweID, typMap M.! mweID))
        Just typ -> (M.insert mweID typ typMap, (mweID, typ))


-- | Preserve only selected MWE annotations.
preserveOnly :: MweTyp -> Sent -> Sent
preserveOnly mweTyp =
  map update
  where
    update tok = tok {mwe = filter preserve (mwe tok)}
    preserve (_, typ) = typ == mweTyp


-- | Inverse of `decorate`.
abstract :: Sent -> MaySent
abstract =
  snd . List.mapAccumL update S.empty -- . tail
  where
    update idSet tok =
      let (idSet', mwe') = List.mapAccumL updateOne idSet (mwe tok)
      in  (idSet', tok {mwe=mwe'})
    updateOne idSet (mweID, mweTyp) =
      if S.member mweID idSet
      then (idSet, (mweID, Nothing))
      else (S.insert mweID idSet, (mweID, Just mweTyp))


-----------------------------------
-- Merging
-----------------------------------


-- | Merge the two .cupt files, i.e., copy the tokens which are in the first
-- file but not in the second one to the second one.
mergeCupt
  :: [[GenSent mwe]]
  -> [[GenSent mwe]]
  -> [[GenSent mwe]]
mergeCupt xss yss =
  map (uncurry mergePar) (zip xss yss)
  where
    mergePar xs ys = map (uncurry mergeSent) (zip xs ys)


-- | Merge the two .cupt sentences, i.e., copy the tokens which are in the first
-- sentence but not in the second one to the second one.
mergeSent
  :: GenSent mwe
  -> GenSent mwe
  -> GenSent mwe
mergeSent =
  go
  where
    go (x:xs) (y:ys)
      | tokID x < tokID y = x : go xs (y:ys)
      | tokID x == tokID y = y : go xs ys
      | otherwise = error "Cupt.mergeSent: impossible happened"
    go (x:xs) [] = x:xs
    go [] [] = []
    go [] (_:_) = error "Cupt.mergeSent: impossible2 happened"


--------------------------------------------------
-- Cleaning up
--------------------------------------------------


-- | Clear the MWE annotations of the given type(s).  If the input set of
-- `MweTyp`es is empty, the function will remove all the MWE annotations.
removeMweAnnotations :: S.Set MweTyp -> MaySent -> MaySent
removeMweAnnotations mweTypSet 
  = abstract
  . map clear
  . decorate
  where
    clear tok = tok
      { mwe = filter
          (\(_id, typ) -> preserve typ)
          (mwe tok)
      }
    preserve typ
      | S.null mweTypSet = False
      | otherwise = typ `S.member` mweTypSet


-----------------------------------
-- Utils
-----------------------------------


-- | A version of `List.groupBy` which always looks at the adjacent elements.
groupBy :: (a -> a -> Bool) -> [a] -> [[a]]
groupBy _ [] = []
groupBy _ [x] = [[x]]
groupBy eq (x : y : rest)
  | eq x y = addHD x $ groupBy eq (y : rest)
  | otherwise = [x] : groupBy eq (y : rest)
  where
    addHD v (xs : xss) = (v : xs) : xss
    addHD v [] = [[v]]
