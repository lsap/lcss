--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE QuasiQuotes #-}
import           Data.Monoid
import           Hakyll

import qualified Data.HashMap.Strict as M
import Data.List.Split
import Data.List
import Data.Maybe
import Control.Arrow
import Control.Monad
import Data.String.Interpolate


--------------------------------------------------------------------------------
main :: IO ()
main = hakyll $ do
    match "images/*" $ do
        route   idRoute
        compile copyFileCompiler

    match "css/*" $ do
        route   idRoute
        compile compressCssCompiler

    match "text/*.md" $ do
        route $ customRoute $ dropPrefix "text/" . unmdize . toFilePath
        compile $ pandocCompiler
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls
                >>= imageRefsCompiler "images/"

    match ("text/plugins/*.md" .||. "text/plugins/*/*.md") $ do
        route $ customRoute $ dropPrefix "text/plugins/" . unmdize . toFilePath
        compile $ pandocCompiler
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls
                >>= imageRefsCompiler "images/"

    create ["plugins"] $ do
        route idRoute
        compile $ do
            plugins <- loadAll "text/plugins/*.md"
            let pluginsCtx =
                    listField "plugins" defaultContext (return plugins) <>
                    constField "title" "Plugins" <>
                    defaultContext
            makeItem ""
                >>= loadAndApplyTemplate "templates/plugins.html" pluginsCtx
                >>= loadAndApplyTemplate "templates/default.html" pluginsCtx
                >>= relativizeUrls

    match "templates/*" $ compile templateBodyCompiler

unmdize :: String -> String
unmdize s = take (length s - 3) s

dropPrefix :: String -> String -> String
dropPrefix s = drop $ length s

--------------------------------------------------------------------------------
postCtx :: Context String
postCtx =
    dateField "date" "%B %e, %Y" `mappend`
    defaultContext


imageRefsCompiler :: String -> Item String -> Compiler (Item String)
imageRefsCompiler imgs t = do
    chunks <- mapM imageSizeFiller $ toChunks $ itemBody t
    mapM thumbnailsCompiler chunks
    pure t { itemBody = concatMap showChunk chunks }

imageSizeFiller :: ExtractChunk -> Compiler ExtractChunk
imageSizeFiller c@ChunkImgRef {} = do
    [w, h] <- words <$> unixFilter "identify" ["-format", "%w %h", imgUrl c] ""
    let dims = Just (read w, read h)
    pure c { imgDims = combine (imgDims c) dims, imgSrcDims = dims }
    where combine DimsUnknown dims = fromMaybeBoth dims
          combine d _ = d
imageSizeFiller c = pure c

thumbnailsCompiler :: ExtractChunk -> Compiler ExtractChunk
thumbnailsCompiler c@ChunkImgRef { .. } | toMaybeBoth imgDims /= imgSrcDims = do
    let thumbName = thumbFilename imgDims imgUrl
    unixFilter "convert" [imgUrl, "-geometry", geom imgDims, thumbName] ""
    pure c
    where geom (BothKnown (w, h)) = show w <> "x" <> show h
          geom (WidthKnown w) = show w <> "x" <> show (snd $ fromJust imgSrcDims)
          geom (HeightKnown h) = show (fst $ fromJust imgSrcDims) <> "x" <> show h
          geom DimsUnknown = error "thumbnailsCompiler: dimensions of the thumbnail are fully unknown"
thumbnailsCompiler c = pure c

data ImgAlign = AlignLeft | AlignRight | AlignInline deriving (Eq, Show)

data ImgDims = DimsUnknown
             | WidthKnown Int
             | HeightKnown Int
             | BothKnown (Int, Int)
             deriving (Eq, Show)

toMaybeBoth :: ImgDims -> Maybe (Int, Int)
toMaybeBoth (BothKnown p) = Just p
toMaybeBoth _ = Nothing

fromMaybeBoth :: Maybe (Int, Int) -> ImgDims
fromMaybeBoth (Just p) = BothKnown p
fromMaybeBoth _ = DimsUnknown

data ExtractChunk = ChunkText String
                  | ChunkImgRef {
                        imgUrl :: String,
                        imgTitle :: String,
                        imgAlign :: ImgAlign,
                        imgIsLink :: Bool,
                        imgDims :: ImgDims,
                        imgSrcDims :: Maybe (Int, Int)
                    } deriving (Eq, Show)

showChunk :: ExtractChunk -> String
showChunk (ChunkText s) = s
showChunk ChunkImgRef { .. } | imgIsLink = [i|<a href="#{imgUrl}"><img src="#{thumbFilename imgDims imgUrl}" alt="#{imgTitle}" /></a>|]
                             | otherwise = [i|<img src="#{imgUrl}" alt="#{imgTitle}" />|]

thumbFilename :: ImgDims -> String -> String
thumbFilename dims s = n <> "hakyllthumb_" <> showDims dims <> "." <> ext
    where (ext, n) = join (***) reverse $ break (== '.') $ reverse s
          showDims (BothKnown (w, h)) = show w <> "_" <> show h
          showDims (WidthKnown w) = "w" <> show w
          showDims (HeightKnown h) = "h" <> show h
          showDims DimsUnknown = error "Dimensions should be known by this point"

toChunks :: String -> [ExtractChunk]
toChunks s = ChunkText h : concatMap (\(a, b) -> [a, b]) (buildChunk <$> rest)
    where (h:rest) = splitOn "[img_assist|" s

buildChunk :: String -> (ExtractChunk, ExtractChunk)
buildChunk s = (parseExpr expr, ChunkText rest)
    where (expr, _:rest) = break (== ']') s

parseExpr :: String -> ExtractChunk
parseExpr s = ChunkImgRef { .. }
    where sts = M.fromList $ (second tail . break (== '=') <$>) $ splitOn "|" s
          imgUrl | Just url <- M.lookup "url" sts = url
                 | otherwise = error $ "No url in image expr: `" <> s <> "`"
          imgTitle = M.lookupDefault "" "title" sts
          imgAlign | Nothing <- val = AlignInline
                   | Just "left" <- val = AlignLeft
                   | Just "right" <- val = AlignRight
                   | Just "inline" <- val = AlignInline
                   | Just x <- val = error $ "Unknown image alignment: " <> x
            where val = M.lookup "align" sts
          imgIsLink = isJust $ M.lookup "link" sts
          imgDims | Just mw' <- mw
                  , Just mh' <- mh = BothKnown (mw', mh')
                  | Just mw' <- mw = WidthKnown mw'
                  | Just mh' <- mh = HeightKnown mh'
                  | otherwise = DimsUnknown
            where mw = read <$> M.lookup "width" sts
                  mh = read <$> M.lookup "height" sts
          imgSrcDims = Nothing
