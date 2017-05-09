module Renderer.TOC (toc, diffTOC, JSONSummary(..), Summarizable(..), isErrorSummary) where

import Category as C
import Data.Aeson
import Data.Functor.Both hiding (fst, snd)
import qualified Data.Functor.Both as Both
import Data.Text (toLower)
import Data.Record
import Diff
import Info
import Prologue
import Renderer.Summary (Summaries(..))
import qualified Data.List as List
import qualified Data.Map as Map hiding (null)
import Source hiding (null)
import Syntax as S
import Term
import Patch

data JSONSummary = JSONSummary { info :: Summarizable }
                 | ErrorSummary { error :: Text, errorSpan :: SourceSpan }
                 deriving (Generic, Eq, Show)

instance ToJSON JSONSummary where
  toJSON (JSONSummary Summarizable{..}) = object [ "changeType" .= summarizableChangeType, "category" .= toCategoryName summarizableCategory, "term" .= summarizableTermName, "span" .= summarizableSourceSpan ]
  toJSON ErrorSummary{..} = object [ "error" .= error, "span" .= errorSpan ]

isErrorSummary :: JSONSummary -> Bool
isErrorSummary ErrorSummary{} = True
isErrorSummary _ = False

data DiffInfo = DiffInfo
  { infoCategory :: Maybe Category
  , infoName :: Text
  , infoSpan :: SourceSpan
  }
  deriving (Eq, Show)

data TOCSummary a = TOCSummary
  { summaryPatch :: Patch a
  , parentInfo :: Maybe Summarizable
  }
  deriving (Eq, Functor, Show, Generic)

data Summarizable
  = Summarizable
    { summarizableCategory :: Category
    , summarizableTermName :: Text
    , summarizableSourceSpan :: SourceSpan
    , summarizableChangeType :: Text
    }
  deriving (Eq, Show)

toc :: HasDefaultFields fields => Both SourceBlob -> Diff (Syntax Text) (Record fields) -> Summaries
toc blobs diff = Summaries changes errors
  where
    changes = if null changes' then mempty else Map.singleton summaryKey (toJSON <$> changes')
    errors = if null errors' then mempty else Map.singleton summaryKey (toJSON <$> errors')
    (errors', changes') = List.partition isErrorSummary summaries
    summaries = diffTOC blobs diff

    summaryKey = toS $ case runJoin (path <$> blobs) of
      (before, after) | null before -> after
                      | null after -> before
                      | before == after -> after
                      | otherwise -> before <> " -> " <> after

diffTOC :: HasDefaultFields fields => Both SourceBlob -> Diff (Syntax Text) (Record fields) -> [JSONSummary]
diffTOC blobs = removeDupes . diffToTOCSummaries >=> toJSONSummaries
  where
    removeDupes :: [TOCSummary DiffInfo] -> [TOCSummary DiffInfo]
    removeDupes = foldl' go []
      where
        go xs x | (_, _ : _) <- find exactMatch x xs = xs
                | (front, TOCSummary _ (Just info) : back) <- find similarMatch x xs =
                  front <> (x { parentInfo = Just (info { summarizableChangeType = "modified" }) } : back)
                | otherwise = xs <> [x]
        find p x = List.break (p x)
        exactMatch a b = parentInfo a == parentInfo b
        similarMatch a b = case (parentInfo a, parentInfo b) of
          (Just (Summarizable catA nameA _ _), Just (Summarizable catB nameB _ _)) -> catA == catB && toLower nameA == toLower nameB
          (_, _) -> False

    diffToTOCSummaries = para $ \diff -> case diff of
      Free r
        | Just identifier <- identifierFor diffSource diffUnwrap r ->
          foldMap (fmap (contextualize (Summarizable (category (Both.snd (headF r))) identifier (sourceSpan (Both.snd (headF r))) "modified")) . snd) r
        | otherwise -> foldMap snd r
      Pure patch -> fmap summarize (sequenceA (runBothWith mapPatch (toInfo . source <$> blobs) patch))

    summarize patch = TOCSummary patch (infoCategory >>= summarizable)
      where DiffInfo{..} = afterOrBefore patch
            summarizable category = Summarizable category infoName infoSpan (patchType patch) <$ find (category ==) [C.Function, C.Method, C.SingletonMethod]

    contextualize info summary = summary { parentInfo = Just (fromMaybe info (parentInfo summary)) }

    diffSource diff = case runFree diff of
      Free (Join (_, a) :< r) -> termFSource (source (Both.snd blobs)) (a :< r)
      Pure a -> termFSource (source (Both.snd blobs)) (runCofree (afterOrBefore a))


toInfo :: HasDefaultFields fields => Source -> Term (Syntax Text) (Record fields) -> [DiffInfo]
toInfo source = para $ \ c -> let termName = fromMaybe (textFor source (byteRange (headF c))) (identifierFor (termFSource source . runCofree) (Just . runCofree) c) in case tailF c of
  S.ParseError{} -> [DiffInfo Nothing termName (sourceSpan (headF c))]
  S.Indexed{} -> foldMap snd c
  S.Fixed{} -> foldMap snd c
  S.Commented{} -> foldMap snd c
  S.AnonymousFunction{} -> [DiffInfo (Just C.AnonymousFunction) termName (sourceSpan (headF c))]
  _ -> [DiffInfo (Just (category (headF c))) termName (sourceSpan (headF c))]

identifierFor :: (a -> Text) -> (a -> Maybe (TermF (Syntax Text) annotation a)) -> TermF (Syntax Text) annotation (a, b) -> Maybe Text
identifierFor getSource project (_ :< syntax) = case syntax of
  S.Function (identifier, _) _ _ -> Just $ getSource identifier
  S.Method _ (identifier, _) Nothing _ _ -> Just $ getSource identifier
  S.Method _ (identifier, _) (Just (receiver, _)) _ _
    | Just (_ :< S.Indexed [receiverParams]) <- project receiver
    , Just (_ :< S.ParameterDecl (Just ty) _) <- project receiverParams -> Just $ "(" <> getSource ty <> ") " <> getSource identifier
    | otherwise -> Just $ getSource receiver <> "." <> getSource identifier
  _ -> Nothing

diffUnwrap :: Diff f (Record fields) -> Maybe (TermF f (Both (Record fields)) (Diff f (Record fields)))
diffUnwrap diff = case runFree diff of
  Free r -> Just r
  _ -> Nothing

termFSource :: HasField fields Range => Source -> TermF f (Record fields) a -> Text
termFSource source = toText . flip Source.slice source . byteRange . headF

textFor :: Source -> Range -> Text
textFor source = toText . flip Source.slice source

toJSONSummaries :: TOCSummary DiffInfo -> [JSONSummary]
toJSONSummaries TOCSummary{..} = case infoCategory of
  Nothing -> [ErrorSummary infoName infoSpan]
  _ -> maybe [] (pure . JSONSummary) parentInfo
  where DiffInfo{..} = afterOrBefore summaryPatch

-- The user-facing category name
toCategoryName :: Category -> Text
toCategoryName category = case category of
  C.SingletonMethod -> "Method"
  c -> show c
