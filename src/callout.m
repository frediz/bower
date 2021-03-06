% Bower - a frontend for the Notmuch email system
% Copyright (C) 2011 Peter Wang

:- module callout.
:- interface.

:- import_module bool.
:- import_module io.
:- import_module list.
:- import_module maybe.
:- import_module pair.

:- import_module data.
:- import_module json.
:- import_module prog_config.
:- import_module quote_arg.

%-----------------------------------------------------------------------------%

:- pred get_notmuch_config(prog_config::in, string::in,
    maybe_error(string)::out, io::di, io::uo) is det.

:- pred get_notmuch_config0(command_prefix::in, string::in,
    maybe_error(string)::out, io::di, io::uo) is det.

:- pred get_notmuch_config(prog_config::in, string::in, string::in,
    maybe_error(string)::out, io::di, io::uo) is det.

:- pred run_notmuch(prog_config::in, list(string)::in,
    pred(json, T)::in(pred(in, out) is det), maybe_error(T)::out,
    io::di, io::uo) is det.

:- pred run_notmuch(prog_config::in, list(string)::in,
    pred(json, T)::in(pred(in, out) is det), redirect_stderr::in,
    maybe_error(T)::out, io::di, io::uo) is det.

:- pred parse_messages_list(json::in, list(message)::out) is det.

:- pred parse_top_message(json::in, message::out) is det.

:- pred parse_message_for_recall(json::in, message_for_recall::out) is det.

:- pred parse_part(message_id::in, bool::in, json::in, part::out) is det.

:- pred parse_threads_list(json::in, list(thread)::out) is det.

:- pred parse_message_id_list(json::in, list(message_id)::out) is det.

:- pred parse_address_count_list(json::in, list(pair(int, string))::out)
    is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module float.
:- import_module map.
:- import_module parsing_utils.
:- import_module require.
:- import_module set.
:- import_module string.

:- import_module call_system.
:- import_module string_util.
:- import_module time_util.

%-----------------------------------------------------------------------------%

get_notmuch_config(Config, Key, Res, !IO) :-
    get_notmuch_command(Config, Notmuch),
    get_notmuch_config0(Notmuch, Key, Res, !IO).

get_notmuch_config0(Notmuch, Key, Res, !IO) :-
    make_quoted_command(Notmuch, ["config", "get", Key],
        redirect_input("/dev/null"), no_redirect, redirect_stderr("/dev/null"),
        run_in_foreground, Command),
    call_system_capture_stdout(Command, no, Res0, !IO),
    (
        Res0 = ok(Value0),
        Value = string.strip(Value0),
        Res = ok(Value)
    ;
        Res0 = error(Error),
        Notmuch = command_prefix(shell_quoted(NotmuchString), _),
        string.append_list(["Error running ", NotmuchString, ": ",
            io.error_message(Error)], Message),
        Res = error(Message)
    ).

get_notmuch_config(Config, Section, Key, Res, !IO) :-
    get_notmuch_config(Config, quote_arg(Section ++ "." ++ Key), Res, !IO).

%-----------------------------------------------------------------------------%

run_notmuch(Config, Args, P, Result, !IO) :-
    RedirectStderr = no_redirect,
    run_notmuch(Config, Args, P, RedirectStderr, Result, !IO).

run_notmuch(Config, Args, P, RedirectStderr, Result, !IO) :-
    get_notmuch_command(Config, Notmuch),
    make_quoted_command(Notmuch, Args,
        redirect_input("/dev/null"), no_redirect, RedirectStderr,
        run_in_foreground, Command),
    promise_equivalent_solutions [Result, !:IO] (
        call_command_parse_json(Command, P, Result, !IO)
    ).

:- pred call_command_parse_json(string::in, pred(json, T)::in(pred(in, out) is det),
    maybe_error(T)::out, io::di, io::uo) is cc_multi.

call_command_parse_json(Command, P, Result, !IO) :-
    call_system_capture_stdout(Command, no, CommandResult, !IO),
    (
        CommandResult = ok(String),
        parse_json(String, ParseResult),
        (
            ParseResult = ok(JSON),
            P(JSON, T),
            Result = ok(T)
        ;
            ParseResult = error(yes(Msg), Line, Column),
            string.format("line %d, column %d: %s",
                [i(Line), i(Column), s(Msg)], ErrorMsg),
            Result = error(ErrorMsg)
        ;
            ParseResult = error(no, Line, Column),
            string.format("line %d, column %d",
                [i(Line), i(Column)], ErrorMsg),
            Result = error(ErrorMsg)
        )
    ;
        CommandResult = error(Error),
        Result = error(io.error_message(Error))
    ).

%-----------------------------------------------------------------------------%

parse_messages_list(JSON, Messages) :-
    ( JSON = list([List]) ->
        parse_inner_message_list(List, Messages)
    ; JSON = list([]) ->
        Messages = []
    ;
        notmuch_json_error
    ).

parse_top_message(JSON, Message) :-
    parse_message_details(JSON, [], Message).

:- pred parse_inner_message_list(json::in, list(message)::out) is det.

parse_inner_message_list(JSON, Messages) :-
    ( JSON = list(Array) ->
        list.map(parse_message, Array, Messagess),
        list.condense(Messagess, Messages)
    ;
        notmuch_json_error
    ).

:- pred parse_message(json::in, list(message)::out) is det.

parse_message(JSON, Messages) :-
    ( JSON = list([JSON1, JSON2]) ->
        parse_inner_message_list(JSON2, Replies),
        ( JSON1 = null ->
            (
                Replies = [],
                Messages = []
            ;
                Replies = [_ | _],
                Messages = [excluded_message(Replies)]
            )
        ;
            parse_message_details(JSON1, Replies, Message),
            Messages = [Message]
        )
    ;
        notmuch_json_error
    ).

:- pred parse_message_details(json::in, list(message)::in, message::out)
    is det.

parse_message_details(JSON, Replies, Message) :-
    parse_message_for_recall(JSON, Message0),
    Message0 = message_for_recall(MessageId, Timestamp, Headers, TagSet),
    parse_body(JSON, MessageId, Body),
    Message = message(MessageId, Timestamp, Headers, TagSet, Body, Replies).

parse_message_for_recall(JSON, Message) :-
    (
        JSON/"id" = unesc_string(Id),
        MessageId = message_id(Id),
        JSON/"timestamp" = int(TimestampInt),   % Y2038
        JSON/"headers" = map(HeaderMap),
        map.foldl(parse_header, HeaderMap, init_headers, Headers),
        JSON/"tags" = list(TagsList),
        list.map(parse_tag, TagsList, Tags)
    ->
        Timestamp = timestamp(float(TimestampInt)),
        TagSet = set.from_list(Tags),
        Message = message_for_recall(MessageId, Timestamp, Headers, TagSet)
    ;
        notmuch_json_error
    ).

:- pred parse_header(string::in, json::in, headers::in, headers::out) is semidet.

parse_header(Key, unesc_string(Value), !Headers) :-
    ( Key = "Date" ->
        !Headers ^ h_date := header_value(Value)
    ; Key = "From" ->
        !Headers ^ h_from := header_value(Value)
    ; Key = "To" ->
        !Headers ^ h_to := header_value(Value)
    ; Key = "Cc" ->
        !Headers ^ h_cc := header_value(Value)
    ; Key = "Bcc" ->
        !Headers ^ h_bcc := header_value(Value)
    ; Key = "Subject" ->
        % notmuch should provide the decoded value.
        !Headers ^ h_subject := decoded_unstructured(Value)
    ; Key = "Reply-To" ->
        !Headers ^ h_replyto := header_value(Value)
    ; Key = "References" ->
        !Headers ^ h_references := header_value(Value)
    ; Key = "In-Reply-To" ->
        !Headers ^ h_inreplyto := header_value(Value)
    ;
        % Some other headers should be decoded_unstructured as well.
        Rest0 = !.Headers ^ h_rest,
        map.insert(Key, header_value(Value), Rest0, Rest),
        !Headers ^ h_rest := Rest
    ).

:- pred parse_body(json::in, message_id::in, list(part)::out) is det.

parse_body(JSON, MessageId, Body) :-
    ( JSON/"body" = list(BodyList) ->
        IsDecrypted = no,
        list.map(parse_part(MessageId, IsDecrypted), BodyList, Body)
    ;
        notmuch_json_error
    ).

parse_part(MessageId, IsDecrypted0, JSON, Part) :-
    (
        JSON/"id" = int(PartId),
        JSON/"content-type" = unesc_string(ContentType)
    ->
        % NOTE: ContentType must be compared case-insensitively.
        ( strcase_prefix(ContentType, "multipart/") ->
            ( JSON/"content" = list(SubParts0) ->
                ( strcase_equal(ContentType, "multipart/encrypted") ->
                    ( JSON/"encstatus" = EncStatus ->
                        ( parse_encstatus(EncStatus, Encryption0) ->
                            Encryption = Encryption0
                        ;
                            notmuch_json_error
                        )
                    ;
                        Encryption = encrypted
                    ),
                    (
                        Encryption = decryption_good,
                        IsDecrypted = yes
                    ;
                        ( Encryption = encrypted
                        ; Encryption = decryption_bad
                        ; Encryption = not_encrypted % should not occur
                        ),
                        IsDecrypted = no
                    )
                ;
                    Encryption = not_encrypted,
                    IsDecrypted = IsDecrypted0
                ),
                ( JSON/"sigstatus" = SigStatus ->
                    ( parse_sigstatus(SigStatus, Signatures0) ->
                        Signatures = Signatures0
                    ;
                        notmuch_json_error
                    )
                ;
                    Signatures = []
                ),
                list.map(parse_part(MessageId, IsDecrypted), SubParts0, SubParts),
                Content = subparts(Encryption, Signatures, SubParts),
                MaybeFilename = no,
                MaybeEncoding = no,
                MaybeLength = no
            ;
                notmuch_json_error
            )
        ; strcase_equal(ContentType, "message/rfc822") ->
            ( JSON/"content" = list(List) ->
                list.map(parse_encapsulated_message(MessageId, IsDecrypted0),
                    List, EncapMessages),
                Content = encapsulated_messages(EncapMessages),
                MaybeFilename = no,
                MaybeEncoding = no,
                MaybeLength = no,
                IsDecrypted = IsDecrypted0
            ;
                notmuch_json_error
            )
        ;
            % Leaf part.
            ( JSON/"content" = unesc_string(ContentString) ->
                Content = text(ContentString)
            ;
                % "content" is unavailable for non-text parts.
                % We can those by running notmuch show --part=N id:NNN
                Content = unsupported
            ),
            ( JSON/"filename" = unesc_string(Filename) ->
                MaybeFilename = yes(Filename)
            ;
                MaybeFilename = no
            ),
            ( JSON/"content-transfer-encoding" = unesc_string(Encoding) ->
                MaybeEncoding = yes(Encoding)
            ;
                MaybeEncoding = no
            ),
            ( JSON/"content-length" = int(Length) ->
                MaybeLength = yes(Length)
            ;
                MaybeLength = no
            ),
            IsDecrypted = IsDecrypted0
        ),
        Part = part(MessageId, yes(PartId), ContentType, Content,
            MaybeFilename, MaybeEncoding, MaybeLength, IsDecrypted)
    ;
        notmuch_json_error
    ).

:- pred parse_encstatus(json::in, encryption::out) is semidet.

parse_encstatus(JSON, Encryption) :-
    JSON = list([Obj]),
    Obj/"status" = unesc_string(Status),
    (
        Status = "good",
        Encryption = decryption_good
    ;
        Status = "bad",
        Encryption = decryption_bad
    ).

:- pred parse_sigstatus(json::in, list(signature)::out) is semidet.

parse_sigstatus(JSON, Signatures) :-
    JSON = list(Objs),
    map(parse_signature, Objs, Signatures).

:- pred parse_signature(json::in, signature::out) is semidet.

parse_signature(JSON, Signature) :-
    JSON/"status" = unesc_string(Status0),
    (
        Status0 = "none", % documented but not in the source code?
        SigStatus = none
    ;
        Status0 = "good",
        ( JSON/"fingerprint" = unesc_string(Fingerprint) ->
            MaybeFingerprint = yes(Fingerprint)
        ;
            MaybeFingerprint = no
        ),
        ( JSON/"created" = int(Created) ->  % Y2038
            MaybeCreated = yes(timestamp(float(Created)))
        ;
            MaybeCreated = no
        ),
        ( JSON/"expires" = int(Expires) ->  % Y2038
            MaybeExpires = yes(timestamp(float(Expires)))
        ;
            MaybeExpires = no
        ),
        ( JSON/"userid" = unesc_string(UserId) ->
            MaybeUserId = yes(UserId)
        ;
            MaybeUserId = no
        ),
        SigStatus = good(MaybeFingerprint, MaybeCreated, MaybeExpires,
            MaybeUserId)
    ;
        (
            Status0 = "bad",
            Status1 = bad
        ;
            Status0 = "error",
            Status1 = error
        ;
            Status0 = "unknown",
            Status1 = unknown
        ),
        ( JSON/"keyid" = unesc_string(KeyId) ->
            MaybeKeyId = yes(KeyId)
        ;
            MaybeKeyId = no
        ),
        SigStatus = not_good(Status1, MaybeKeyId)
    ),
    ( JSON/"errors" = int(Errors0) ->
        Errors = Errors0
    ;
        Errors = 0
    ),
    Signature = signature(SigStatus, Errors).

:- pred parse_encapsulated_message(message_id::in, bool::in, json::in,
    encapsulated_message::out) is det.

parse_encapsulated_message(MessageId, IsDecrypted0, JSON, EncapMessage) :-
    (
        JSON/"headers" = map(HeaderMap),
        map.foldl(parse_header, HeaderMap, init_headers, Headers),
        JSON/"body" = list(BodyList),
        list.map(parse_part(MessageId, IsDecrypted0), BodyList, Body)
    ->
        EncapMessage = encapsulated_message(Headers, Body)
    ;
        notmuch_json_error
    ).

%-----------------------------------------------------------------------------%

parse_threads_list(Json, Threads) :-
    ( Json = list(List) ->
        list.map(parse_thread, List, Threads)
    ;
        notmuch_json_error
    ).

:- pred parse_thread(json::in, thread::out) is det.

parse_thread(Json, Thread) :-
    (
        Json/"thread" = unesc_string(Id),
        Json/"timestamp" = int(Timestamp), % Y2038
        Json/"authors" = unesc_string(Authors),
        Json/"subject" = unesc_string(Subject),
        Json/"tags" = list(TagsList),
        Json/"matched" = int(Matched),
        Json/"total" = int(Total),
        list.map(parse_tag, TagsList, Tags)
    ->
        TagSet = set.from_list(Tags),
        Thread = thread(thread_id(Id), timestamp(float(Timestamp)), Authors,
            Subject, TagSet, Matched, Total)
    ;
        notmuch_json_error
    ).

:- pred parse_tag(json::in, tag::out) is semidet.

parse_tag(Json, tag(Tag)) :-
    Json = unesc_string(Tag).

%-----------------------------------------------------------------------------%

parse_message_id_list(JSON, MessageId) :-
    (
        JSON = list(List),
        list.map(parse_message_id, List, MessageId0)
    ->
        MessageId = MessageId0
    ;
        notmuch_json_error
    ).

:- pred parse_message_id(json::in, message_id::out) is semidet.

parse_message_id(unesc_string(Id), message_id(Id)).

%-----------------------------------------------------------------------------%

parse_address_count_list(Json, AddressCounts) :-
    ( Json = list(List) ->
        list.map(parse_address_count, List, AddressCounts)
    ;
        notmuch_json_error
    ).

:- pred parse_address_count(json::in, pair(int, string)::out) is det.

parse_address_count(Json, Result) :-
    (
        Json/"count" = int(Count),
        Json/"name-addr" = unesc_string(NameAddr)
    ->
        Result = Count - NameAddr
    ;
        notmuch_json_error
    ).

%-----------------------------------------------------------------------------%

:- func json / string = json is semidet.

map(Map) / Key = Value :-
    map.search(Map, Key, Value).

:- func unesc_string(string::out) = (json::in) is semidet.

unesc_string(unescape(EscString)) = string(EscString).

:- pred notmuch_json_error is erroneous.

notmuch_json_error :-
    error("notmuch_json_error").

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
