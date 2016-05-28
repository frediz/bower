% Bower - a frontend for the Notmuch email system
% Copyright (C) 2013 Peter Wang

:- module send_util.
:- interface.

:- import_module io.
:- import_module maybe.
:- import_module stream.

:- import_module data.
:- import_module rfc5322.
:- import_module splitmix64.

:- pred generate_date_msg_id(header_value::out, header_value::out,
    io::di, io::uo) is det.

:- type write_header_options
    --->    no_encoding
    ;       rfc2047_encoding.

:- pred write_address_list_header(write_header_options::in, Stream::in,
    string::in, address_list::in, maybe_error::in, maybe_error::out,
    State::di, State::uo) is det <= stream.writer(Stream, string, State).

:- pred write_as_unstructured_header(write_header_options::in, Stream::in,
    string::in, header_value::in, State::di, State::uo) is det
    <= stream.writer(Stream, string, State).

:- pred write_references_header(Stream::in,
    string::in, header_value::in, State::di, State::uo) is det
    <= stream.writer(Stream, string, State).

:- pred generate_boundary(string::out, splitmix64::in, splitmix64::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module bool.
:- import_module char.
:- import_module int.
:- import_module list.
:- import_module require.
:- import_module string.
:- import_module time.

:- import_module fold_lines.
:- import_module rfc2047.
:- import_module rfc2047.encoder.
:- import_module rfc5322.writer.
:- import_module sys_util.
:- import_module time_util.

:- mutable(msgid_counter, int, 0, ground, [untrailed, attach_to_io_state]).

%-----------------------------------------------------------------------------%

generate_date_msg_id(header_value(Date), header_value(MessageId), !IO) :-
    current_timestamp(Time, !IO),
    localtime(Time, TM, GMTOffSecs, !IO),
    Year = 1900 + TM ^ tm_year,
    Month = 1 + TM ^ tm_mon,
    Day = TM ^ tm_mday,
    Hour = TM ^ tm_hour,
    Min = TM ^ tm_min,
    Sec = TM ^ tm_sec,
    Wday = TM ^ tm_wday,
    (
        weekday_short_name(Wday, WdayName0),
        month_short_name(Month, MonthName0)
    ->
        WdayName = WdayName0,
        MonthName = MonthName0
    ;
        unexpected($module, $pred, "bad weekday or month")
    ),
    GMTOffMins = GMTOffSecs // 60,
    TzHour = GMTOffMins // 60, % include sign
    TzMin = abs(GMTOffMins) mod 60,
    Date = string.format("%s, %d %s %d %02d:%02d:%02d %+03d%02d",
        [s(WdayName), i(Day), s(MonthName), i(Year), i(Hour), i(Min), i(Sec),
        i(TzHour), i(TzMin)]),

    % This emulates the Message-ID generated by Mutt.

    get_msgid_counter(Counter0, !IO),
    char.det_from_int(65 + Counter0, Char),
    Counter = (Counter0 + 1) mod 26,
    set_msgid_counter(Counter, !IO),

    get_pid(Pid, !IO),
    get_hostname(HostName, !IO),
    get_domainname(DomainName, !IO),
    MessageId = string.format("<%04d%02d%02d%02d%02d%02d.G%c%d@%s.%s>",
        [i(Year), i(Month), i(Day), i(Hour), i(Min), i(Sec),
        c(Char), i(Pid), s(HostName), s(DomainName)]).

%-----------------------------------------------------------------------------%

write_address_list_header(Opt0, Stream, Field, Addresses, !Error, !State) :-
    (
        Opt0 = no_encoding,
        Opt = no_encoding
    ;
        Opt0 = rfc2047_encoding,
        Opt = rfc2047_encoding
    ),
    address_list_to_spans(Opt, Addresses, [], Spans0, yes, Ok),
    maybe_record_error(Field, Ok, !Error),
    add_field_span(Field, Spans0, Spans),
    fill_lines(soft_line_length, Spans, Lines),
    do_write_header(Stream, Lines, !State).

:- pred address_list_to_spans(options::in, address_list::in,
    list(span)::in, list(span)::out, bool::in, bool::out) is det.

address_list_to_spans(_Opt, [], !Spans, !AllValid).
address_list_to_spans(Opt, [Address | Addresses], !Spans, !AllValid) :-
    (
        Addresses = [],
        LastElement = yes
    ;
        Addresses = [_ | _],
        address_list_to_spans(Opt, Addresses, !Spans, !AllValid),
        LastElement = no
    ),
    address_to_span(Opt, Address, LastElement, !Spans, !AllValid).

:- pred address_to_span(options::in, address::in, bool::in,
    list(span)::in, list(span)::out, bool::in, bool::out) is det.

address_to_span(Opt, Address, LastElement, !Spans, !AllValid) :-
    Address = mailbox(_),
    address_to_string(Opt, Address, String, Valid),
    (
        LastElement = yes,
        Span = span(String, "")
    ;
        LastElement = no,
        Span = span(String ++ ",", " ")
    ),
    cons(Span, !Spans),
    bool.and(Valid, !AllValid).
address_to_span(Opt, Address, LastElement, !Spans, !AllValid) :-
    Address = group(DisplayName, Mailboxes),
    (
        LastElement = yes,
        CloseSpan = span(";", "")
    ;
        LastElement = no,
        CloseSpan = span(";,", " ")
    ),
    cons(CloseSpan, !Spans),
    mailboxes_to_spans(Opt, Mailboxes, !Spans, !AllValid),
    group_name_to_span(Opt, DisplayName, !Spans, !AllValid).

:- pred group_name_to_span(options::in, display_name::in,
    list(span)::in, list(span)::out, bool::in, bool::out) is det.

group_name_to_span(Opt, DisplayName, !Spans, !AllValid) :-
    display_name_to_string(Opt, DisplayName, String, Valid),
    cons(span(String ++ ":", " "), !Spans),
    bool.and(Valid, !AllValid).

:- pred mailboxes_to_spans(options::in, list(mailbox)::in,
    list(span)::in, list(span)::out, bool::in, bool::out) is det.

mailboxes_to_spans(_Opt, [], !Spans, !AllValid).
mailboxes_to_spans(Opt, [Mailbox | Mailboxes], !Spans, !AllValid) :-
    (
        Mailboxes = [],
        LastElement = yes
    ;
        Mailboxes = [_ | _],
        mailboxes_to_spans(Opt, Mailboxes, !Spans, !AllValid),
        LastElement = no
    ),
    mailbox_to_span(Opt, Mailbox, LastElement, !Spans, !AllValid).

:- pred mailbox_to_span(options::in, mailbox::in, bool::in,
    list(span)::in, list(span)::out, bool::in, bool::out) is det.

mailbox_to_span(Opt, Mailbox, LastElement, !Spans, !AllValid) :-
    mailbox_to_string(Opt, Mailbox, MailboxString, Valid),
    bool.and(Valid, !AllValid),
    (
        LastElement = yes,
        Span = span(MailboxString, "")
    ;
        LastElement = no,
        Span = span(MailboxString ++ ",", " ")
    ),
    cons(Span, !Spans).

:- pred maybe_record_error(string::in, bool::in,
    maybe_error::in, maybe_error::out) is det.

maybe_record_error(Field, Ok, Error0, Error) :-
    (
        Ok = no,
        Error0 = ok
    ->
        Error = error("Invalid address list in " ++ Field ++ " header.")
    ;
        Error = Error0
    ).

write_as_unstructured_header(Opt, Stream, Field, Value, !State) :-
    (
        Value = header_value(ValueString)
    ;
        Value = decoded_unstructured(Decoded),
        (
            Opt = no_encoding,
            ValueString = Decoded
        ;
            Opt = rfc2047_encoding,
            encode_unstructured(Decoded, ValueString)
        )
    ),
    get_spans_by_whitespace(ValueString, ValueSpans),
    add_field_span(Field, ValueSpans, Spans),
    fill_lines(soft_line_length, Spans, Lines),
    do_write_header(Stream, Lines, !State).

write_references_header(Stream, Field, Value, !State) :-
    write_as_unstructured_header(no_encoding, Stream, Field, Value, !State).

:- pred add_field_span(string::in, list(span)::in, list(span)::out) is det.

add_field_span(Field, Spans0, Spans) :-
    FieldColon = Field ++ ":",
    (
        Spans0 = [],
        Spans = [span(FieldColon, "")]
    ;
        Spans0 = [Head0 | Tail],
        Head0 = span(Mandatory, Trailer),
        Head = span(FieldColon ++ " " ++ lstrip(Mandatory), Trailer),
        Spans = [Head | Tail]
    ).

:- pred do_write_header(Stream::in, list(string)::in, State::di, State::uo)
    is det <= stream.writer(Stream, string, State).

do_write_header(_Stream, [], !State).
do_write_header(Stream, [Line | Lines], !State) :-
    put(Stream, Line, !State),
    (
        Lines = [],
        put(Stream, "\n", !State)
    ;
        Lines = [_ | _],
        put(Stream, "\n ", !State),
        do_write_header(Stream, Lines, !State)
    ).

:- func soft_line_length = int.

soft_line_length = 78.

%-----------------------------------------------------------------------------%

generate_boundary(Boundary, !RS) :-
    % This emulates the boundaries generated by Mutt.
    list.map_foldl(generate_boundary_char, 1 .. 16, Chars, !RS),
    string.from_char_list(Chars, Boundary).

:- pred generate_boundary_char(int::in, char::out,
    splitmix64::in, splitmix64::out) is det.

generate_boundary_char(_, Char, !RS) :-
    next(I, !RS),
    Index = I /\ 0x3f,
    string.unsafe_index(base64_chars, Index, Char).

:- func base64_chars = string.

base64_chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
