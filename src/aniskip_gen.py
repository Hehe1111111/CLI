#!/usr/bin/env python3
"""AniSkip lua + ffmetadata generator.

stdin: AniSkip v1 JSON (api.aniskip.com/v1/skip-times response)
argv1: cache path for the lua file ("/tmp/ani-cli_skip_<mal>_<ep>.lua")

stdout: nothing (the shell echoes the cache path itself)

Exit codes:
  0 = lua + ffmetadata written
  2 = no usable skip data (cache file left empty so we don't refetch)
  1 = bad input / internal error (cache removed by caller)

This used to be an inline `python3 -c "..."` heredoc inside watch.sh.
The nested quoting (Lua double-quoted strings inside a double-quoted
shell heredoc inside a single-quoted Lua triple-alpha) broke silently
on rc=1 with empty stderr — the classic "AniSkip doesn't work" bug.
A real file has no quoting pitfalls and is debuggable standalone:
  curl -s URL | python3 aniskip_gen.py /tmp/x.lua
"""
import sys
import json


def main():
    cache = sys.argv[1]
    try:
        d = json.load(sys.stdin)
    except (ValueError, json.JSONDecodeError):
        sys.exit(1)
    if not d.get('found'):
        open(cache, 'w').close()
        sys.exit(2)
    ivals = []
    for r in d.get('results', []):
        iv = r.get('interval', {})
        s, e, t = iv.get('start_time'), iv.get('end_time'), r.get('skip_type', '')
        if s is None or e is None:
            continue
        span = e - s
        if span < 5 or span > 600:
            continue
        l = r.get('episode_length') or 0
        ivals.append((float(s), float(e), t, float(l)))
    if not ivals:
        open(cache, 'w').close()
        sys.exit(2)

    lines = ['local intervals = {']
    for s, e, t, l in ivals:
        lines.append('  { s = %.3f, e = %.3f, t = %s, l = %.3f, done = false },'
                     % (s, e, json.dumps(t), l))
    lines.append('}')
    # The Lua observer body — this block is exactly why the old heredoc died.
    # In a standalone file there is no shell-quoting layer at all.
    lua_body = """local LEN_TOLERANCE = 120

mp.observe_property("time-pos", "number", function(_, pos)
    if not pos then return end
    local dur = mp.get_property_number("duration")
    for _, iv in ipairs(intervals) do
        if not iv.done then
            local len_ok = (not dur) or iv.l == 0 or math.abs(dur - iv.l) <= LEN_TOLERANCE
            if len_ok and pos >= iv.s and pos < iv.e - 0.5 then
                iv.done = true
                mp.set_property_number("time-pos", iv.e)
                mp.osd_message("Skipped " .. iv.t, 2)
                return
            end
        end
    end
end)"""
    lines.append(lua_body)
    with open(cache, 'w') as f:
        f.write('\n'.join(lines) + '\n')

    names = {'op': 'Opening', 'ed': 'Ending'}
    chaps = [';FFMETADATA1']
    for s, e, t, l in sorted(ivals):
        chaps.append('[CHAPTER]')
        chaps.append('TIMEBASE=1/1000')
        chaps.append('START=%d' % int(s * 1000))
        chaps.append('END=%d' % int(e * 1000))
        chaps.append('title=' + names.get(t, t.upper()))
    fm = cache[:-4] + '.ffmetadata' if cache.endswith('.lua') else cache + '.ffmetadata'
    with open(fm, 'w') as f:
        f.write('\n'.join(chaps) + '\n')


if __name__ == '__main__':
    main()
