#!/bin/sh
# Tiny POSIX-shell YAML loader for PVR config files.
#
# Reads simple YAML files and exposes values as shell variables or
# evaluates them into the current shell. Supports the subset that the
# PVR config files actually use:
#
#   key: value
#   key2:
#     subkey: value
#   list_key:
#     - item1
#     - item2
#
# Does NOT support full YAML — no anchors, no flow style, no multi-doc.
# That is fine for our configs, which are edited by humans.
#
# Internal line format: "VAL <path>	<value>" and
# "LIST <path>	<item>". Tab is the field separator because values
# can legitimately contain "|" (e.g. ffmpeg filter expressions).
#
# Public API:
#
#   load_config FILE key1=default1 key2.subkey=default2 ...
#       Sets KEY1, KEY2_SUBKEY shell variables in the calling shell.
#
#   load_config_eval FILE [prefix=PREFIX] key1=default1 ...
#       Prints assignment statements (use with eval). With prefix=,
#       leading segments are stripped from each key, so e.g.
#       prefix=profiles.high_quality on key
#       "profiles.high_quality.video.codec" yields variable
#       "video_codec".
#
#   load_list FILE list_key OUTPUT_FILE
#       Writes list items, one per line, to the output file.

# _yaml_flatten FILE
# Prints "VAL <path>	<value>" or "LIST <path>	<value>" lines.
_yaml_flatten() {
    _file="$1"
    _path=""
    _cur_indent=-1
    _saw_root=0

    while IFS= read -r _raw || [ -n "$_raw" ]; do
        # Strip comments and trailing whitespace.
        _line=$(printf '%s' "$_raw" | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//')
        [ -z "$_line" ] && continue

        # Leading-space count.
        _lead=$(printf '%s' "$_line" | awk 'match($0, /^ */) { print RLENGTH }')

        # If a new root-level key appears, drop the path stack.
        if [ "$_lead" -eq 0 ]; then
            if [ "$_saw_root" -eq 1 ]; then
                _path=""
                _cur_indent=0
            fi
            _saw_root=1
        fi

        # Pop stack on dedent.
        while [ "$_lead" -lt "$_cur_indent" ] && [ "$_cur_indent" -gt 0 ]; do
            _cur_indent=$((_cur_indent - 2))
            _path=$(printf '%s' "$_path" | sed 's/\.[^.]*$//')
        done

        # List item: line whose first non-space char is "-".
        _first_nonspace=$(printf '%s' "$_line" | awk '{print $1}')
        if [ "$_first_nonspace" = "-" ]; then
            _item=$(printf '%s' "$_line" | sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)/\1/p')
            _item=$(printf '%s' "$_item" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
            printf 'LIST %s\t%s\n' "$_path" "$_item"
            continue
        fi

        # "key: value" or "key:" (section header).
        case "$_line" in
            *":"*)
                _key=$(printf '%s' "$_line" | sed -n 's/^[[:space:]]*\([^:][^:]*\):.*/\1/p')
                # Capture content AFTER the colon+whitespace. Empty
                # here means a section header; non-empty means a leaf
                # value (including "key: \"\"" which is an empty
                # string value, NOT a section).
                _after=$(printf '%s' "$_line" | sed -n 's/^[^:]*:[[:space:]]*\(.*\)/\1/p')
                if [ -z "$_after" ]; then
                    # Section header.
                    if [ -z "$_path" ]; then
                        _path="$_key"
                    else
                        _path="$_path.$_key"
                    fi
                    _cur_indent=$((_lead + 2))
                else
                    # Leaf.
                    if [ -z "$_path" ]; then
                        _full="$_key"
                    else
                        _full="$_path.$_key"
                    fi
                    _val=$(printf '%s' "$_after" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
                    # Sentinel for "value present but empty". A
                    # literal TAB distinguishes a present-but-empty
                    # value from "key missing entirely" in the
                    # downstream loader. We emit "<EMPTY>" as the
                    # value marker, which load_config_eval recognises
                    # and converts back to "".
                    if [ -z "$_val" ]; then
                        printf 'VAL %s\t<EMPTY>\n' "$_full"
                    else
                        printf 'VAL %s\t%s\n' "$_full" "$_val"
                    fi
                fi
                ;;
        esac
    done < "$_file"
}

# _get_val <pairs> "<key.path>"
# Returns the value, or "" if the key is missing.
# If the key is present-but-empty, returns "<EMPTY>" sentinel so the
# caller can distinguish "no value" from "empty string value".
_get_val() {
    _pairs="$1"
    _key="$2"
    printf '%s\n' "$_pairs" | grep -F "VAL $_key	" | head -n1 | cut -f2-
}

load_config() {
    _file="$1"
    shift
    _pairs=$(_yaml_flatten "$_file")

    for _spec in "$@"; do
        _key=$(printf '%s' "$_spec" | sed -n 's/^\([^=]*\)=.*/\1/p')
        _default=$(printf '%s' "$_spec" | sed -n 's/^[^=]*=\(.*\)/\1/p')
        _value=$(_get_val "$_pairs" "$_key")
        # If _value is the <EMPTY> sentinel, treat it as a present
        # empty string — DO NOT fall back to default.
        if [ "$_value" = "<EMPTY>" ]; then
            _value=""
        elif [ -z "$_value" ]; then
            _value="$_default"
        fi
        _var=$(printf '%s' "$_key" | tr '.-/' '___')
        eval "${_var}=\$(printf '%s' \"\$_value\")"
    done
}

load_config_eval() {
    _file="$1"
    shift

    _pfx=""
    case "${1:-}" in
        prefix=*)
            _pfx="${1#prefix=}"
            shift
            ;;
    esac

    _pairs=$(_yaml_flatten "$_file")

    for _spec in "$@"; do
        _key=$(printf '%s' "$_spec" | sed -n 's/^\([^=]*\)=.*/\1/p')
        _default=$(printf '%s' "$_spec" | sed -n 's/^[^=]*=\(.*\)/\1/p')
        _value=$(_get_val "$_pairs" "$_key")
        # If _value is the <EMPTY> sentinel, treat it as a present
        # empty string — DO NOT fall back to default.
        if [ "$_value" = "<EMPTY>" ]; then
            _value=""
        elif [ -z "$_value" ]; then
            _value="$_default"
        fi
        if [ -n "$_pfx" ]; then
            # Strip the prefix from the key so the resulting variable
            # name reflects only the suffix.
            case "$_key" in
                "${_pfx}."*) _bare="${_key#${_pfx}.}" ;;
                *) _bare="$_key" ;;
            esac
            _var=$(printf '%s' "$_bare" | tr '.-/' '___')
        else
            _var=$(printf '%s' "$_key" | tr '.-/' '___')
        fi
        _qval=$(printf '%s' "$_value" | sed "s/'/'\\\\''/g")
        printf "%s='%s'\n" "$_var" "$_qval"
    done
}

load_list() {
    _file="$1"
    _key="$2"
    _out="$3"
    : > "$_out"
    _pairs=$(_yaml_flatten "$_file")
    printf '%s\n' "$_pairs" \
        | grep -E "LIST [a-zA-Z0-9_.-]*\\.${_key}	|LIST ${_key}	" \
        | sed "s/^LIST [a-zA-Z0-9_.-.]*	//" >> "$_out"
}