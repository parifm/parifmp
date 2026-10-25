#!/opt/homebrew/bin/bash
# PreToolUse Bash guard: refuses a heredoc that can
# end early (nested or stray same terminator), a python stdin heredoc that writes
# files, launchctl bootout/bootstrap on a variable target, and rm -r on a path
# that starts with an unguarded variable. It fails open, with a systemMessage.
# Tests: ~/.claude/hooks/heredoc-guard-tests/run.sh
export LC_ALL=C
shopt -s extglob
LOG=${HEREDOC_GUARD_LOG:-$HOME/.claude/hooks/heredoc-guard.log}
MAXLEN=200000
in=$(cat)

log() { printf '%s %s %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG"; }
# a guard that cannot look says so, and allows: a deny here would block every session
fail_open() {
    local m="heredoc-guard could not check this command ($1); it ran unchecked"
    if [ -n "$jqp" ]; then jq -nc --arg s "$m" '{systemMessage:$s}'
    else printf '{"systemMessage":"heredoc-guard could not check this command (no jq); it ran unchecked"}\n'; fi
    log allow-unchecked "$1"
    exit 0
}
jqp=$(command -v jq) || fail_open "jq not found"
tool=$(printf '%s' "$in" | jq -r '.tool_name // ""') || fail_open "hook input is not JSON"
[ "$tool" = Bash ] || exit 0
cmd=$(printf '%s' "$in" | jq -r '.tool_input.command // ""') || fail_open "jq could not read tool_input.command"
agent=$(printf '%s' "$in" | jq -r '.agent_type // ""')
[ -n "$cmd" ] || exit 0
[[ $cmd == *'<<'* || $cmd == *launchctl* || $cmd == *rm* ]] || exit 0
(( ${#cmd} <= MAXLEN )) || fail_open "command is ${#cmd} bytes, over the $MAXLEN-byte scan limit"

# opener after "<<": optional -, optional quote or backslash, an identifier word
re_open="^(-?)[[:space:]]*([\"']?)\\\\?([A-Za-z_][A-Za-z0-9_]*)([\"']?)"
re_py='(^|[[:space:];&|(`/])python[0-9.]*([[:space:]]+-[A-Za-z]+)*([[:space:]]+-)?[[:space:]]*$'
re_pyw="open\\(.*,[[:space:]]*(mode[[:space:]]*=[[:space:]]*)?[\"'][wa][bt+]{0,2}[\"']|\\.write_(text|bytes)\\("
re_lc='launchctl[[:space:]]+(bootout|bootstrap)[[:space:]]+(.*)'
re_rm='(^|[[:space:];&|(`{/\\])rm[[:space:]]+(.*)'
re_guard='^"?\$\{[A-Za-z_][A-Za-z0-9_]*:\?'
# rm/launchctl count only as a command word: after a separator, a keyword like
# sudo/xargs/then (with flags or VAR=x), or a path such as /bin/
re_cmdpos='(^|[;&|({`!]|(^|[[:space:];&|({`])(then|do|else|if|while|until|sudo|xargs|exec|command|nohup|time|env|builtin))([[:space:]]+-[^[:space:]]*)*([[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)*[[:space:]]*\\?([^[:space:]]*/)?$'
re_q="^([^\"']*)([\"'])(.*)\$"
# a heredoc body is checked for d/e only when a shell reads it
re_sh='(^|[[:space:];&|(`])(bash|sh|zsh|ksh|dash|ssh|sudo)([[:space:]]|$)'

RULES='' HITS=()
hit() { RULES+=$1; HITS+=("$2"); }
# extglob trims (${x##+(...)}) are quadratic in bash, so trim only short strings
cut80() { local s=${1:0:200}; s=${s##+([[:space:]])}; (( ${#s} <= 80 )) || s="${s:0:77}..."; printf '%s' "$s"; }

# mask LINE [OPENQUOTE]: MS = LINE at the same length with the inside of '…' and
# "…" blanked, so `echo "rm -rf $x"` holds no command word; OPENQUOTE is a quote
# left open by an earlier line. Lines over 4000 chars stay unmasked (cost).
mask() {
    local s=$1 q=${2:-} out='' inner
    if (( ${#s} > 4000 )); then MS=$s; return 0; fi
    s=${s//\\\"/__}; s=${s//\\\'/__}
    while :; do
        if [[ -z $q ]]; then
            [[ $s =~ $re_q ]] || break
            out+=${BASH_REMATCH[1]}_; q=${BASH_REMATCH[2]}; s=${BASH_REMATCH[3]}
        fi
        if [[ $s != *"$q"* ]]; then out+=${s//?/_}; s=''; break; fi
        inner=${s%%"$q"*}
        out+=${inner//?/_}_; s=${s:${#inner}+1}; q=''
    done
    MS=$out$s
}
# cmdpos PREFIX: true when the text before rm/launchctl puts it in command position
cmdpos() {
    local p=$1
    (( ${#p} <= 200 )) || p=x${p: -200}
    [[ $p =~ $re_cmdpos ]]
}

# scan LINE ARRAY: walk one line, carrying quote and substitution context in the
# global stk (S single, A $'', D double, C $(, P (, B backtick, R arithmetic);
# append each heredoc opener in unquoted text to ARRAY as "dash word offset"
scan() {
    local full=$1 n=${#1} base=0 s i c t prev=' ' m
    local -n out=$2
    # walk in 256-char windows (+64 lookahead): a bash substring costs time in
    # proportion to the string, so ${s:i:1} over a whole long line is quadratic
    while (( base < n )); do
    s=${full:base:320}; i=0
    while (( i < 256 && base + i < n )); do
        c=${s:i:1}; t=${stk: -1}
        case $t in
        S) [[ $c != "'" ]] || stk=${stk%?}; i=$((i+1)); continue ;;
        A) if [[ $c == '\' ]]; then i=$((i+2)); continue; fi
           [[ $c != "'" ]] || stk=${stk%?}; i=$((i+1)); continue ;;
        D) case $c in
           '\') i=$((i+2)); continue ;;
           '"') stk=${stk%?} ;;
           '`') stk+=B ;;
           '$') if [[ ${s:i+1:2} == '((' ]]; then stk+=R; i=$((i+3)); continue
                elif [[ ${s:i+1:1} == '(' ]]; then stk+=C; i=$((i+2)); continue; fi ;;
           esac
           i=$((i+1)); continue ;;
        esac
        case $c in
        '\') i=$((i+2)); prev=x; continue ;;
        "'") stk+=S ;;
        '"') stk+=D ;;
        '`') if [[ $t == B ]]; then stk=${stk%?}; else stk+=B; fi ;;
        '$') case ${s:i+1:1} in
             "'") stk+=A; i=$((i+2)); continue ;;
             '(') if [[ ${s:i+2:1} == '(' ]]; then stk+=R; i=$((i+3)); else stk+=C; i=$((i+2)); fi
                  prev=x; continue ;;
             '{') m=${s:i}; m=${m%%\}*}; i=$((i+${#m}+1)); prev=x; continue ;;
             esac ;;
        '(') if [[ ${s:i+1:1} == '(' && $prev == [[:space:]\;\&\|\(] ]]; then stk+=R; i=$((i+2)); continue; fi
             stk+=P ;;
        ')') case $t in
             C|P) stk=${stk%?} ;;
             R) if [[ ${s:i+1:1} == ')' ]]; then stk=${stk%?}; i=$((i+2)); prev=x; continue; fi ;;
             esac ;;
        '#') [[ $prev != [[:space:]\;\&\|\(] ]] || return 0 ;;
        '<') if [[ ${s:i:3} == '<<<' ]]; then i=$((i+3)); prev=x; continue; fi
             if [[ ${s:i+1:1} == '<' && $t != R && ${s:i+2} =~ $re_open && ${BASH_REMATCH[2]} == "${BASH_REMATCH[4]}" ]]; then
                 out+=("${BASH_REMATCH[1]:-x} ${BASH_REMATCH[3]} $((base+i))")
                 i=$((i+2+${#BASH_REMATCH[0]})); prev=x; continue
             fi ;;
        esac
        prev=$c; i=$((i+1))
    done
    base=$((base+i))
    done
    return 0
}

# toks ARGS: split rm's arguments into raw words (quotes kept) up to the end of the command
toks() {
    local s=$1 n=${#1} i=0 c q='' cur='' have=0
    TK=()
    while (( i < n )); do
        c=${s:i:1}
        if [[ -n $q ]]; then
            cur+=$c
            if [[ $c == '\' && $q == '"' ]]; then cur+=${s:i+1:1}; i=$((i+2)); continue; fi
            [[ $c != "$q" ]] || q=''
            i=$((i+1)); continue
        fi
        case $c in
        [[:space:]]) if (( have )); then TK+=("$cur"); cur=''; have=0; fi ;;
        ';'|'&'|'|'|')'|'<'|'>') break ;;
        '#') (( have )) || break; cur+=$c ;;
        "'"|'"') q=$c; cur+=$c; have=1 ;;
        '\') cur+=$c${s:i+1:1}; have=1; i=$((i+2)); continue ;;
        *) cur+=$c; have=1 ;;
        esac
        i=$((i+1))
    done
    (( ! have )) || TK+=("$cur")
    return 0
}

# check_de LINE LINENO [OPENQUOTE]: rules d (launchctl target) and e (rm -r path),
# for rm/launchctl in command position outside quotes; comment lines pass
check_de() {
    local s=$1 ln=$2 rest mrest off sub tgt g args t rec dd bad cnt=0
    [[ ! $s =~ ^[[:space:]]*# ]] || return 0
    mask "$s" "${3:-}"
    # each loop rescans the rest of the line, so at most 100 commands per line are checked
    if [[ $s == *launchctl* ]]; then
        rest=$s; mrest=$MS
        while (( cnt++ < 100 )) && [[ $mrest =~ $re_lc ]]; do
            off=$(( ${#mrest} - ${#BASH_REMATCH[0]} ))
            cmdpos "${mrest:0:off}" || { mrest=${mrest:off+9}; rest=${rest:off+9}; continue; }
            [[ ${rest:off} =~ $re_lc ]] || break
            sub=${BASH_REMATCH[1]}; rest=${BASH_REMATCH[2]}; mrest=${mrest:${#mrest}-${#rest}}
            while [[ $rest =~ ^-[^[:space:]]*[[:space:]]+(.*) ]]; do rest=${BASH_REMATCH[1]}; done
            if [[ $rest == \"* ]]; then tgt=${rest:1}; tgt="\"${tgt%%\"*}\""
            elif [[ $rest == \'* ]]; then tgt=''
            else tgt=${rest%%[[:space:]\;\&\|\)]*}; fi
            tgt=${tgt:0:300}; g=${tgt//\$\{+([A-Za-z0-9_]):\?*([^\}])\}/}
            [[ $g != *'$'* ]] || hit d "line $ln: launchctl $sub target $(cut80 "$tgt") holds a variable"
        done
    fi
    if [[ $s == *rm* ]]; then
        rest=$s; mrest=$MS; cnt=0
        while (( cnt++ < 100 )) && [[ $mrest =~ $re_rm ]]; do
            off=$(( ${#mrest} - ${#BASH_REMATCH[0]} + ${#BASH_REMATCH[1]} ))
            args=${rest:off+2}
            t=${mrest:0:off}; mrest=${mrest:off+2}; rest=$args
            cmdpos "$t" || continue
            toks "${args:0:1000}"
            rec=0 dd=0 bad=''
            for t in "${TK[@]}"; do
                if (( ! dd )) && [[ $t == -- ]]; then dd=1; continue; fi
                if (( ! dd )) && [[ $t == -* ]]; then
                    [[ ! ( $t == --recursive || $t =~ ^-[A-Za-z]*[rR] ) ]] || rec=1
                    continue
                fi
                if [[ -z $bad && ( $t == '$'* || $t == '"$'* ) && ! $t =~ $re_guard ]]; then bad=$t; fi
            done
            (( ! rec )) || [[ -z $bad ]] || hit e "line $ln: rm -r on $(cut80 "$bad"), which starts with a variable"
        done
    fi
    return 0
}

mapfile -t L < <(printf '%s\n' "$cmd")
n=${#L[@]}
declare -A closed=()
stk='' k=0
while (( k < n )); do
    line=${L[k]}; ln=$((k+1)); k=$((k+1))
    # rule b, checked whatever the quote state: after a heredoc closed early the
    # rest of its body runs as shell and may leave a quote open
    # a terminator line is short; longer lines skip the (quadratic) extglob trim
    tr=''; (( ${#line} > 300 )) || { tr=${line##+([[:space:]])}; tr=${tr%%+([[:space:]])}; }
    if [[ -n $tr && -n ${closed[$tr]:-} ]]; then
        hit b "line $ln is a bare $tr after the <<$tr heredoc opened on line ${closed[$tr]} had already closed: that heredoc ended early and the lines between ran as shell"
    fi
    case ${stk: -1} in S|A) q0="'" ;; D) q0='"' ;; *) q0='' ;; esac
    check_de "$line" "$ln" "$q0"
    OPN=()
    [[ $line != *'<<'* && $line != *[\'\"\`\(\)\$\\]* ]] || scan "$line" OPN
    for o in "${OPN[@]}"; do
        read -r dash W pos <<< "$o"
        py=0; [[ ! ${line:0:pos} =~ $re_py ]] || py=1
        sh=0; (( ${#line} > 4000 )) || [[ ! $line =~ $re_sh ]] || sh=1
        start=$ln
        while (( k < n )); do
            bl=${L[k]}; bn=$((k+1)); k=$((k+1))
            cmpl=$bl; [[ $dash != - ]] || (( ${#bl} > 300 )) || cmpl=${bl##+($'\t')}
            if [[ $cmpl == "$W" ]]; then closed[$W]=$start; break; fi
            if [[ $bl == *'<<'* ]]; then
                save=$stk; stk=''; BO=()
                scan "$bl" BO
                stk=$save
                for b in "${BO[@]}"; do
                    read -r _ bw _ <<< "$b"
                    [[ $bw != "$W" ]] || hit a "line $bn opens another <<$W inside the <<$W heredoc opened on line $start: the first bare $W line closes the outer heredoc and the lines after it run as shell"
                done
            fi
            (( ! sh )) || check_de "$bl" "$bn"
            if (( py )) && [[ ! $bl =~ ^[[:space:]]*# && $bl =~ $re_pyw ]]; then
                hit c "the python heredoc opened on line $start writes a file (line $bn: $(cut80 "$bl"))"
            fi
        done
    done
done

(( ${#HITS[@]} )) || exit 0
fix=''
[[ $RULES != *[ab]* ]] || fix+=" Use the Edit/Write tool to write files, or a different terminator for the inner heredoc."
[[ $RULES != *c* ]] || fix+=" Use the Write/Edit tool to write or change files; a python heredoc should only read."
[[ $RULES != *d* ]] || fix+=" An empty variable widens a launchctl target (an empty label left gui/501/, which logs the user out): use a literal target, e.g. gui/501/com.example.label."
[[ $RULES != *e* ]] || fix+=" An empty variable turns the rm path into / or the working folder: write it as \"\${VAR:?}/path\" so an empty one aborts."
rl=$(printf '%s' "$RULES" | fold -w1 | sort -u | paste -sd, -)
# the first hit of each rule, then a count of the rest
body='' shown=0 seen=''
for (( h=0; h<${#HITS[@]}; h++ )); do
    r=${RULES:h:1}
    [[ $seen != *$r* ]] || continue
    seen+=$r; body+="${HITS[h]}; "; shown=$((shown+1))
done
body=${body%; }
(( ${#HITS[@]} == shown )) || body+=" (+$(( ${#HITS[@]} - shown )) more)"
short="heredoc-guard denied (rule $rl): ${HITS[0]}"
reason="heredoc-guard (rule $rl): $body.$fix Rewrite the command."
jq -nc --arg r "$reason" --arg s "$short" '{systemMessage:$s,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
log deny "Bash${agent:+ ($agent)} rules=$rl ${#HITS[@]} hit(s): ${HITS[0]}"
exit 0
