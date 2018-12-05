let s:messages = []
let s:indent   = '  '

let s:separator      = !exists('+shellslash') || &shellslash ? '/' : '\'
let s:json_tests_dir = expand('%:p:h:h').s:separator.'editors-json-tests'


"
" Helper functions
"


function File(...)
  let components = [s:json_tests_dir]
  for arg in a:000
    call extend(components, split(arg, '/'))
  endfor
  return join(components, s:separator)
endfunction


function Log(msg)
  if type(a:msg) == type('')
    call add(s:messages, a:msg)
  elseif type(a:msg) == type([])
    call extend(s:messages, a:msg)
  else
    call add(v:errors, 'Exception: unsupported type: '.type(a:msg))
  endif
endfunction


" Log an error like this:
"
"   function RunTest[10]..Step[7]..<SNR>6_expect_not_request line 3: Expected 'blah' but got ''
"
" As this:
"
"   Expected 'blah' but got ''
"   <SNR>6_expect_not_request:3
"   Step:7
"   function RunTest:10
function LogErrorTrace()
  let i = 0
  for error in v:errors
    if i > 0
      call Log(repeat(s:indent, 3).'--------')
    endif
    for trace in reverse(split(error, '\.\.'))
      if trace =~ ' line \d\+: '
        let m = matchend(trace, ' line \d\+: ')
        call Log(repeat(s:indent, 3).trace[m:])
        call Log(repeat(s:indent, 3).s:normalise_line_number(trace[:m-3]))
      else
        call Log(repeat(s:indent, 3).s:normalise_line_number(trace))
      endif
    endfor
    let i += 1
  endfor
endfunction


" blah_blah line 42 -> blah_blah:42
" blah_blah[42]     -> blah_blah:42
function s:normalise_line_number(str)
  if a:str =~ ' line \d\+$'
    return substitute(a:str, ' line \(\d\+\)$', '\=":".submatch(1)', '')
  elseif a:str =~ '\[\d\+\]$'
    return substitute(a:str, '\[\(\d\+\)\]$', '\=":".submatch(1)', '')
  else
    return a:str
  endif
endfunction


function s:action_open(properties)
  execute 'edit' File(a:properties.file)
  " ignore focus
endfunction


function s:action_new_file(properties)
  execute 'edit' File(a:properties.file)
  if !empty(a:properties.content)
    call s:action_input_text({'text': a:properties.content})
    " call setline(1, a:properties.content)
  endif
endfunction


function s:action_move_cursor(properties)
  " a:properties.offset is 0-based.  Vim's character counts are 1-based.
  call kite#utils#goto_character(a:properties.offset + 1)
endfunction


function s:action_input_text(properties)
  " This fires InsertCharPre before each character but does not fire
  " TextChangedI at all.  So we fire it manually.
  " But test_override('char_avail', 1) works around this (somehow).
  call test_override('char_avail', 1)

  execute 'normal! a'.a:properties.text
  doautocmd KiteEvents TextChangedI

  sleep 50m  " give auto-completion time to happen

  call test_override('char_avail', 0)
endfunction


function s:action_request_hover(properties)
  KiteDocsAtCursor
endfunction


function s:action_request_completion(properties)
  " See https://github.com/vim/vim/blob/master/src/testdir/test_ins_complete.vim
  " call feedkeys("i\<C-X>\<C-U>", "x")

  execute "normal! i\<C-X>\<C-U>"
  sleep 50m  " give async call time to happen
endfunction


function s:expect_request(properties)
  " Give the request time to be sent.
  sleep 5m

  let body_expected = has_key(a:properties, 'body')

  if body_expected
    let body = a:properties.body

    " If body is a string, it is the path to a json file
    if type(body) == 1
      let body = json_decode(join(readfile(File(body)), "\n"))
      let body = s:replace_placeholders(body)
    endif
  endif

  for request in kite#client#request_history()
    if request.method == a:properties.method && request.path == a:properties.path
      if body_expected
        if body == json_decode(request.body)
          call assert_equal(1, 1)  " register success
          return
        endif
      else
        call assert_equal(1, 1)  " register success
        return
      endif
    endif
  endfor

  let errmsg = 'Missing request: '.
        \ 'method='.a:properties.method.' '.
        \ 'path='.a:properties.path
  if body_expected
    let errmsg .= ' body='.json_encode(body)
  endif
  call assert_report(errmsg)
  " call Log(string(kite#client#request_history()))
endfunction


function s:expect_not_request(properties)
  " Give the request time to be sent.
  sleep 5m

  let body_expected = has_key(a:properties, 'body')

  if body_expected
    let body = a:properties.body

    " If body is a string, it is the path to a json file
    if type(body) == 1
      let body = json_decode(join(readfile(File(body)), "\n"))
      let body = s:replace_placeholders(body)
    endif
  endif

  for request in kite#client#request_history()
    if request.method == a:properties.method && request.path == a:properties.path
      if body_expected
        if body == json_decode(request.body)
          call assert_report('Unwanted request: '.
                \ 'method='.a:properties.method.' '.
                \ 'path='.a:properties.path.' '.
                \ 'body='.json_encode(body))
          return
        endif
      else
        call assert_report('Unwanted request: '.
              \ 'method='.a:properties.method.' '.
              \ 'path='.a:properties.path)
      endif
    endif
  endfor

  call assert_equal(1, 1)  " register success
endfunction


function s:expect_request_count(properties)
  " Give the request time to be sent.
  sleep 5m

  let matching_requests = 0
  let requests = kite#client#request_history()
  for request in requests
    if request.method == a:properties.method &&
          \ request.path == a:properties.path
      let matching_requests += 1
    endif
  endfor
  call assert_equal(a:properties.count, matching_requests)
endfunction


function s:expect_not_request_count(properties)
  " Give the request time to be sent.
  sleep 5m

  let matching_requests = 0
  let requests = kite#client#request_history()
  for request in requests
    if request.method == a:properties.method &&
          \ request.path == a:properties.path
      let matching_requests += 1
    endif
  endfor
  call assert_notequal(a:properties.count, matching_requests)
endfunction


function s:replace_placeholders(properties)
  let str = json_encode(a:properties)

  " NOTE: assumes the current file is the one we want, i.e. we don't
  " make any effort to parse <<filepath>> in ${editors.<<filepath>>.*}.
  let placeholders = [
        \ ['\${plugin}',                           'vim'],
        \ ['\${editors\..\{-}\.filename_escaped}', kite#utils#filepath(1)],
        \ ['\${editors\..\{-}\.filename}',         kite#utils#filepath(0)],
        \ ['\${editors\..\{-}\.hash}',             kite#utils#url_encode(kite#utils#buffer_md5())],
        \ ['\${editors\..\{-}\.offset}',           kite#utils#character_offset()]
        \ ]

  for [placeholder, value] in placeholders
    let str = substitute(str, placeholder, value, '')
  endfor

  return json_decode(str)
endfunction


function Step(dict)
  " call Log(a:dict.step.'_'.a:dict.type.' - '.string(a:dict.properties))
  call call('<SID>'.a:dict.step.'_'.a:dict.type, [s:replace_placeholders(a:dict.properties)])
endfunction


function RunTest(testfile)
  call kite#client#reset_request_history()

  execute 'edit' a:testfile
  let json = json_decode(kite#utils#buffer_contents())
  bdelete

  if has_key(json, 'live_environment') && !json.live_environment
    return
  endif

  call Log(json.description.' ('.fnamemodify(a:testfile, ':t').'):')

  for step in json.test
    call Step(step)

    if len(v:errors) == 0
      call Log(s:indent.step.description.' - ok')
    else
      call Log(s:indent.step.description.' - fail')
      call LogErrorTrace()
      break
    endif
  endfor

  " Discard fixture file.  This assumes the test always opened a file, which
  " will be the current buffer.  If this is not always true, we will need to
  " check each buffers' path before discarding.
  bdelete!

  let v:errors = []
endfunction


"
" Run the tests
"


execute 'edit' File('tests', 'default.json')
let features = json_decode(getline(1))
bdelete

for feature in features
  let tests = glob(File('tests', feature, '*.json'), 1, 1)
  for test in tests
    " if test !~ 'completions_spec.json' | continue | endif  " TODO remove this
    call RunTest(test)
  endfor
endfor


"
" Report the log
"


split messages.log
call append(line('$'), s:messages)
write


"
" Finish
"


" qall!