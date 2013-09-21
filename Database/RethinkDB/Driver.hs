module Database.RethinkDB.Driver (
  run,
  run',
  Result(..),
  runOpts,
  RunOptions(..),
  ) where

import Data.Aeson (Value, FromJSON, fromJSON)
import qualified Data.Aeson (Result(Error, Success))
import Control.Monad
import Control.Concurrent.MVar (MVar, takeMVar)
import Data.Sequence ((|>))

import Database.RethinkDB.Protobuf.Ql2.Query (Query(..))
import Database.RethinkDB.Protobuf.Ql2.Query.AssocPair (AssocPair(..))
import Database.RethinkDB.Protobuf.Ql2.Term as Term (Term(..))
import Database.RethinkDB.Protobuf.Ql2.Term.TermType
import Database.RethinkDB.Protobuf.Ql2.Datum as Datum
import Database.RethinkDB.Protobuf.Ql2.Datum.DatumType
import Text.ProtocolBuffers.Basic (uFromString, defaultValue)

import Database.RethinkDB.Network
import Database.RethinkDB.ReQL

-- | Per-query settings
data RunOptions =
  UseOutdated |
  NoReply |
  SoftDurability Bool

applyOption :: RunOptions -> Query -> Query
applyOption UseOutdated q = addQueryOption q "user_outdated" True
applyOption NoReply q = addQueryOption q "noreply" True
applyOption (SoftDurability b) q = addQueryOption q "soft_durability" b

addQueryOption :: Query -> String -> Bool -> Query
addQueryOption q k v = q {
  global_optargs = global_optargs q |> AssocPair (Just $ uFromString k) (Just boolTrue) }
  where
    boolTrue = defaultValue{
      Term.type' = Just DATUM, datum = Just defaultValue{
         Datum.type' = Just R_BOOL, r_bool = Just v } }

-- | Run a query with the given options
runOpts :: (Expr query, Result r) => RethinkDBHandle -> [RunOptions] -> query -> IO r
runOpts h opts t = do
  let (q, bt) = buildQuery (expr t) 0 (rdbDatabase h)
  let q' = foldr (fmap . applyOption) id opts q
  r <- runQLQuery h q' bt
  convertResult r

-- | Run a given query and return a Result
run :: (Expr query, Result r) => RethinkDBHandle -> query -> IO r
run h = runOpts h []

-- | Run a given query and return a Value
run' :: Expr query => RethinkDBHandle -> query -> IO [Value]
run' h t = do
  c <- run h t
  collect c

-- | Convert the raw query response into useful values
class Result r where
  convertResult :: MVar Response -> IO r

instance Result Response where
    convertResult = takeMVar

instance FromJSON a => Result (Cursor a) where
  convertResult r = fmap (fmap $ unsafe . fromJSON) $ makeCursor r
    where
      unsafe (Data.Aeson.Error e) = error e
      unsafe (Data.Aeson.Success a) = a

instance FromJSON a => Result [a] where
  convertResult = collect <=< convertResult
  
instance FromJSON a => Result (Maybe a) where
  convertResult r = do
    c <- convertResult r
    car <- next c
    case car of
      Nothing -> return Nothing
      Just a -> do
        cadr <- next c
        case cadr of
          Nothing -> return $ Just a
          Just _ -> return Nothing