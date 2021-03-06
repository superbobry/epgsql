%%% Copyright (C) 2009 - Will Glozer.  All rights reserved.
%%% Copyright (C) 2011 - Anton Lebedevich.  All rights reserved.

-module(pgsql_wire).

-export([decode_message/1,
         decode_error/1,
         decode_strings/1,
         decode_columns/2,
         encode/1,
         encode/2,
         decode_data/2,
         decode_complete/1,
         encode_types/1,
         encode_formats/1,
         format/1,
         encode_parameters/1]).

-include("pgsql.hrl").
-include("pgsql_binary.hrl").

decode_message(<<Type:8, Len:?int32, Rest/binary>> = Bin) ->
    Len2 = Len - 4,
    case Rest of
        <<Data:Len2/binary, Tail/binary>> ->
            case Type of
                $E ->
                    {{error, decode_error(Data)}, Tail};
                _ ->
                    {{Type, Data}, Tail}
            end;
        _Other ->
            Bin
    end;

decode_message(Bin) ->
    Bin.

%% decode a single null-terminated string
decode_string(Bin) ->
    binary:split(Bin, <<0>>).

%% decode multiple null-terminated string
decode_strings(Bin) ->
    [<<>> | T] = lists:reverse(binary:split(Bin, <<0>>, [global])),
    lists:reverse(T).

%% decode field
decode_fields(Bin) ->
    decode_fields(Bin, []).

decode_fields(<<0>>, Acc) ->
    Acc;
decode_fields(<<Type:8, Rest/binary>>, Acc) ->
    [Str, Rest2] = decode_string(Rest),
    decode_fields(Rest2, [{Type, Str} | Acc]).

%% decode ErrorResponse
%% TODO add fields from http://www.postgresql.org/docs/9.0/interactive/protocol-error-fields.html
decode_error(Bin) ->
    Fields = decode_fields(Bin),
    Error = #error{
      severity = lower_atom(proplists:get_value($S, Fields)),
      code     = proplists:get_value($C, Fields),
      message  = proplists:get_value($M, Fields),
      extra    = decode_error_extra(Fields)},
    Error.

decode_error_extra(Fields) ->
    Types = [{$D, detail}, {$H, hint}, {$P, position}],
    decode_error_extra(Types, Fields, []).

decode_error_extra([], _Fields, Extra) ->
    Extra;
decode_error_extra([{Type, Name} | T], Fields, Extra) ->
    case proplists:get_value(Type, Fields) of
        undefined -> decode_error_extra(T, Fields, Extra);
        Value     -> decode_error_extra(T, Fields, [{Name, Value} | Extra])
    end.

lower_atom(Str) when is_binary(Str) ->
    lower_atom(binary_to_list(Str));
lower_atom(Str) when is_list(Str) ->
    list_to_atom(string:to_lower(Str)).

encode(Data) ->
    Bin = iolist_to_binary(Data),
    <<(byte_size(Bin) + 4):?int32, Bin/binary>>.

encode(Type, Data) ->
    Bin = iolist_to_binary(Data),
    <<Type:8, (byte_size(Bin) + 4):?int32, Bin/binary>>.

%% decode data
decode_data(Columns, Bin) ->
    decode_data(Columns, Bin, []).

decode_data([], _Bin, Acc) ->
    list_to_tuple(lists:reverse(Acc));
decode_data([_C | T], <<-1:?int32, Rest/binary>>, Acc) ->
    decode_data(T, Rest, [undefined | Acc]);
decode_data([C | T], <<Len:?int32, Value:Len/binary, Rest/binary>>, Acc) ->
    case C of
        #column{type = Type, format = 1}   -> Value2 = pgsql_binary:decode(Type, Value);
        #column{}                          -> Value2 = Value
    end,
    decode_data(T, Rest, [Value2 | Acc]).

%% decode column information
decode_columns(Count, Bin) ->
    decode_columns(Count, Bin, []).

decode_columns(0, _Bin, Acc) ->
    lists:reverse(Acc);
decode_columns(N, Bin, Acc) ->
    [Name, Rest] = decode_string(Bin),
    <<_Table_Oid:?int32, _Attrib_Num:?int16, Type_Oid:?int32,
     Size:?int16, Modifier:?int32, Format:?int16, Rest2/binary>> = Rest,
    Desc = #column{
      name     = Name,
      type     = pgsql_types:oid2type(Type_Oid),
      size     = Size,
      modifier = Modifier,
      format   = Format},
    decode_columns(N - 1, Rest2, [Desc | Acc]).

%% decode command complete msg
decode_complete(<<"SELECT", 0>>)        -> select;
decode_complete(<<"SELECT", _/binary>>) -> select;
decode_complete(<<"BEGIN", 0>>)         -> 'begin';
decode_complete(<<"ROLLBACK", 0>>)      -> rollback;
decode_complete(Bin) ->
    [Str, _] = decode_string(Bin),
    case string:tokens(binary_to_list(Str), " ") of
        ["INSERT", _Oid, Rows] -> {insert, list_to_integer(Rows)};
        ["UPDATE", Rows]       -> {update, list_to_integer(Rows)};
        ["DELETE", Rows]       -> {delete, list_to_integer(Rows)};
        ["MOVE", Rows]         -> {move, list_to_integer(Rows)};
        ["FETCH", Rows]        -> {fetch, list_to_integer(Rows)};
        [Type | _Rest]         -> lower_atom(Type)
    end.

%% encode types
encode_types(Types) ->
    encode_types(Types, 0, <<>>).

encode_types([], Count, Acc) ->
    <<Count:?int16, Acc/binary>>;

encode_types([Type | T], Count, Acc) ->
    case Type of
        undefined -> Oid = 0;
        _Any      -> Oid = pgsql_types:type2oid(Type)
    end,
    encode_types(T, Count + 1, <<Acc/binary, Oid:?int32>>).

%% encode column formats
encode_formats(Columns) ->
    encode_formats(Columns, 0, <<>>).

encode_formats([], Count, Acc) ->
    <<Count:?int16, Acc/binary>>;

encode_formats([#column{format = Format} | T], Count, Acc) ->
    encode_formats(T, Count + 1, <<Acc/binary, Format:?int16>>).

format(Type) ->
    case pgsql_binary:supports(Type) of
        true  -> 1;
        false -> 0
    end.

%% encode parameters
encode_parameters(Parameters) ->
    encode_parameters(Parameters, 0, <<>>, <<>>).

encode_parameters([], Count, Formats, Values) ->
    <<Count:?int16, Formats/binary, Count:?int16, Values/binary>>;

encode_parameters([P | T], Count, Formats, Values) ->
    {Format, Value} = encode_parameter(P),
    Formats2 = <<Formats/binary, Format:?int16>>,
    Values2 = <<Values/binary, Value/binary>>,
    encode_parameters(T, Count + 1, Formats2, Values2).

%% encode parameter

encode_parameter({Type, Value}) ->
    case pgsql_binary:encode(Type, Value) of
        Bin when is_binary(Bin) -> {1, Bin};
        {error, unsupported}    -> encode_parameter(Value)
    end;
encode_parameter(A) when is_atom(A)    -> {0, encode_list(atom_to_list(A))};
encode_parameter(B) when is_binary(B)  -> {0, <<(byte_size(B)):?int32, B/binary>>};
encode_parameter(I) when is_integer(I) -> {0, encode_list(integer_to_list(I))};
encode_parameter(F) when is_float(F)   -> {0, encode_list(float_to_list(F))};
encode_parameter(L) when is_list(L)    -> {0, encode_list(L)}.

encode_list(L) ->
    Bin = list_to_binary(L),
    <<(byte_size(Bin)):?int32, Bin/binary>>.
