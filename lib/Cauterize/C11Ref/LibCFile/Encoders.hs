{-# LANGUAGE QuasiQuotes #-}
module Cauterize.C11Ref.LibCFile.Encoders
  ( typeEncoder
  ) where

import Cauterize.C11Ref.Util
import Data.String.Interpolate
import Data.List (intercalate)
import qualified Cauterize.CommonTypes as C
import qualified Cauterize.Specification as S

typeEncoder :: S.Type -> String
typeEncoder t = chompNewline [i|
  R encode_#{name}(EI * const _c_iter, #{decl} const * const _c_obj) {
#{encoderBody t}
  }
|]
  where
    name = ident2str $ S.typeName t
    decl = t2decl t

encoderBody :: S.Type -> String
encoderBody t = b
  where
    n = ident2str $ S.typeName t
    b = case S.typeDesc t of
          S.Synonym { S.synonymRef = r } ->
            synonymEncoderBody (ident2str r)
          S.Range { S.rangeOffset = o, S.rangeLength = l, S.rangeTag = rt } ->
            rangeEncoderBody o l rt
          S.Array { S.arrayRef = r } ->
            arrayEncoderBody (ident2str r)
          S.Vector { S.vectorRef = r, S.vectorTag = lr } ->
            vectorEncoderBody n (ident2str r) lr
          S.Enumeration { S.enumerationValues = vs, S.enumerationTag = et } ->
            enumerationEncoderBody n vs et
          S.Record { S.recordFields = fs } ->
            recordEncoderBody fs
          S.Combination { S.combinationFields = fs, S.combinationTag = fr } ->
            combinationEncoderBody n fs fr
          S.Union { S.unionFields = fs, S.unionTag = tr } ->
            unionEncoderBody n fs tr

synonymEncoderBody :: String -> String
synonymEncoderBody r = [i|    return __caut_encode_#{r}(_c_iter, (#{r} *)_c_obj);|]

rangeEncoderBody :: C.Offset -> C.Length -> C.Tag -> String
rangeEncoderBody o l t = chompNewline [i|
    #{tagt} _c_tag;

    if (*_c_obj < #{rmin} || #{rmax} < *_c_obj) {
      return caut_status_range_out_of_bounds;
    }

    _c_tag = (#{tagt})(*_c_obj + #{o});

    STATUS_CHECK(#{tag2encodefn t}(_c_iter, &_c_tag));

    return caut_status_ok;|]
  where
    tagt = tag2c t
    rmin = fromIntegral o :: Integer
    rmax = fromIntegral o + fromIntegral l :: Integer

arrayEncoderBody :: String -> String
arrayEncoderBody r = chompNewline [i|
    for (size_t _c_i = 0; _c_i < ARR_LEN(_c_obj->elems); _c_i++) {
      STATUS_CHECK(encode_#{r}(_c_iter, &_c_obj->elems[_c_i]));
    }

    return caut_status_ok;|]

vectorEncoderBody :: String -> String -> C.Tag -> String
vectorEncoderBody n r lr = chompNewline [i|
    if (_c_obj->_length > VECTOR_MAX_LEN_#{n}) {
      return caut_status_invalid_length;
    }

    STATUS_CHECK(#{tag2encodefn lr}(_c_iter, &_c_obj->_length));

    for (size_t _c_i = 0; _c_i < _c_obj->_length; _c_i++) {
      STATUS_CHECK(encode_#{r}(_c_iter, &_c_obj->elems[_c_i]));
    }

    return caut_status_ok;|]

enumerationEncoderBody :: String -> [S.EnumVal] -> C.Tag -> String
enumerationEncoderBody _ [] _ = error "enumerationEncoderBody: enumerations must have at least one value."
enumerationEncoderBody n vs t = chompNewline [i|
    #{tagt} _c_tag;

    if (*_c_obj < 0 || #{lsym} < *_c_obj) {
      return caut_status_enumeration_out_of_range;
    }

    _c_tag = (#{tagt})_c_obj;

    STATUS_CHECK(#{tag2encodefn t}(_c_iter, &_c_obj->_length));

    return caut_status_ok;|]
  where
    tagt = tag2c t
    lsym = [i|#{n}_#{S.enumValName (last vs)}|]

recordEncoderBody :: [S.Field] -> String
recordEncoderBody fs =
  let fencs = map (("    " ++) . encodeField) fs
      withReturn = fencs ++ ["", "    return caut_status_ok;"]
  in intercalate "\n" withReturn

combinationEncoderBody :: String -> [S.Field] -> C.Tag -> String
combinationEncoderBody n fs fr =
  let checkFlags  = [i|    if (~COMBINATION_FLAGS_#{n} & _c_obj->_flags) { return caut_status_invalid_flags; }|]
      encodeFlags = [i|    STATUS_CHECK(#{tag2encodefn fr}(_c_iter, &_c_obj->_flags));|] ++ "\n"
      encodeFields = map encodeCombField fs
  in intercalate "\n" $ (checkFlags : encodeFlags : encodeFields) ++ ["", "    return caut_status_ok;"]

unionEncoderBody :: String -> [S.Field] -> C.Tag -> String
unionEncoderBody n fs tr = chompNewline [i|
    #{tr} _temp_tag = (#{tr})_c_obj->_tag;

    if (_temp_tag >= UNION_NUM_FIELDS_#{n}) {
      return caut_status_invalid_tag;
    }

    STATUS_CHECK(#{tag2encodefn tr}(_c_iter, &_temp_tag));

    switch(_c_obj->_tag) {
#{fields}
    }

    return caut_status_ok;|]
  where
    fields = intercalate "\n" $ map (encodeUnionField n) fs

encodeField :: S.Field -> String
encodeField S.DataField { S.fieldName = n, S.fieldRef = r } =
  [i|STATUS_CHECK(encode_#{ident2str r}(_c_iter, &_c_obj->#{ident2str n}));|]
encodeField S.EmptyField { S.fieldName = n, S.fieldIndex = ix } =
  [i|/* No data for field #{ident2str n} with index #{ix}. */|]

encodeCombField :: S.Field -> String
encodeCombField f@S.EmptyField {} = "    " ++ encodeField f
encodeCombField f@S.DataField { S.fieldIndex = ix } = chompNewline [i|
    if (FSET(_c_obj->_flags, #{ix})) { #{encodeField f} }|]

encodeUnionField :: String -> S.Field -> String
encodeUnionField n f = [i|    case #{n}_tag_#{S.fieldName f}: #{encodeField f} break;|]
