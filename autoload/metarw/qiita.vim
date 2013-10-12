let s:save_cpo = &cpo
set cpo&vim

if !exists('g:qiita_token')
  echohl ErrorMsg | echomsg "require 'g:qiita_token' variables" | echohl None
  finish
endif

if !executable('curl')
  echohl ErrorMsg | echomsg "require 'curl' command" | echohl None
  finish
endif

function! s:endpoint_url() " {{{
  return "https://qiita.com/api/v1"
endfunction " }}}

function! s:qiita_path(path) " {{{
  return s:endpoint_url() . a:path . "?token=" . g:qiita_token
endfunction " }}}

function! s:get_title() " {{{
  return getline(1)
endfunction " }}}

function! s:get_body() " {{{
  return join(getline(4, "$"), "\n")
endfunction " }}}

function! s:parse_tags() " {{{
  let line = getline(2)

  if line =~ "^\s*$/"
    return []
  else
    let result = {}

    let items = split(line, " ")
    for tag_info in items
      let name_and_version = split(tag_info, ":")
      if len(name_and_version) == 2
        let [name, tag_version] = name_and_version
        if has_key(result, name)
          call add(result[name], tag_version)
        else
          let result[name] = [tag_version]
        endif
      else
        let name = name_and_version[0]
        let result[name] = []
      endif
    endfor

    return result
  endif
endfunction " }}}

function! s:tags_to_line(_) " {{{
  let result = []
  for t in a:_
    if empty(t.versions)
      call add(result, t.name)
    else
      for v in t.versions
        call add(result, t.name . ":" . v)
      endfor
    endif
  endfor
  return join(result, " ")
endfunction " }}}

function! s:construct_post_data(options) " {{{
  let Private = a:options.private == 1 ?
        \ function('webapi#json#true') :
        \ function('webapi#json#false')

  let Tweet = a:options.tweet == 1 ?
        \ function('webapi#json#true') :
        \ function('webapi#json#false')

  let Gist = a:options.gist == 1 ?
        \ function('webapi#json#true') :
        \ function('webapi#json#false')

  let tag_info = []
  for [name, versions] in items(s:parse_tags())
    call add(tag_info, {'name' : name, 'versions' : versions})
  endfor

  let data = {
        \ "title" : s:get_title(),
        \ "tags" : tag_info,
        \ "body" : s:get_body(),
        \ "private" : Private,
        \ "tweet" : Tweet,
        \ "gist" : Gist,
        \ }

  return data
endfunction " }}}

function! s:post_current(options) " {{{
  echo a:options
  let data = s:construct_post_data(a:options)
  let json = webapi#json#encode(data)
  let res = webapi#http#post(s:qiita_path("/items"), json, {"Content-type" : "application/json"})
  let content = webapi#json#decode(res.content)

  if res.status =~ "^2.*"
    echomsg content.url
    let b:qiita_metadata = {
          \ 'private' : content.private,
          \ 'url' : content.url,
          \}
    return ['done', '']
  else
    return ['error', 'Failed to post new item']
  endif
endfunction " }}}

function! s:update_item(uuid, options) " {{{
  let data = s:construct_post_data(a:options)
  call remove(data, 'private')
  call remove(data, 'tweet')
  call remove(data, 'gist')
  let json = webapi#json#encode(data)
  let res = webapi#http#post(s:qiita_path("/items/" . a:uuid), json, {"Content-type" : "application/json"}, "PUT")
  let content = webapi#json#decode(res.content)

  if res.status =~ "^2.*"
    echomsg content.url
    return ['done', '']
  else
    return ['error', 'Failed to update item']
  endif
endfunction " }}}

function! s:read_content(uuid) " {{{
  let res = webapi#http#get(s:qiita_path("/items/" . a:uuid))
  let content = webapi#json#decode(res.content)

  let body = join([content.title, s:tags_to_line(content.tags), "", content.raw_body], "\n")
  put =body
  set ft=markdown
  let b:qiita_metadata = {
        \ 'private' : content.private,
        \ 'url' : content.url,
        \}

  return ['done', '']
endfunction " }}}

function! s:read_user(user) " {{{
  let res = webapi#http#get(s:qiita_path("/users/" . a:user . "/items"))
  let content = webapi#json#decode(res.content)
  let list = map(content,
    \ '{"label" : v:val.title, "fakepath" : "qiita:items/" . v:val.uuid}')
  echo list
  return ["browse", list]
endfunction " }}}

function! metarw#qiita#complete(arglead, cmdline, cursorpos)
endfunction

function! s:parse_options(str) " {{{
  let result = {}
  let pairs = split(a:str, "&")
  for p in pairs
    let [key, value] = split(p, '=')
    let result[key] = value
  endfor
  return result
endfunction " }}}

function! metarw#qiita#read(fakepath) " {{{
  let _ = s:parse_incomplete_fakepath(a:fakepath)
  if _.mode == "items"
    return s:read_content(_.path)
  elseif _.mode == "users"
    return s:read_user(_.path)
  endif
endfunction " }}}

function! metarw#qiita#write(fakepath, line1, line2, append_p) " {{{
  let _ = s:parse_incomplete_fakepath(a:fakepath)
  if _.mode == "write_new"
    let result = s:post_current(_.options)
  elseif _.mode == "items"
    let result = s:update_item(_.path, _.options)
  endif
  return result
endfunction " }}}

function! s:parse_incomplete_fakepath(incomplete_fakepath) " {{{
  let _ = {
        \ 'mode' : '',
        \ 'path' : '',
        \ 'options' : {'private' : 0, 'tweet' : 0, 'gist' : 0}
        \ }

  let fragments = split(a:incomplete_fakepath, '^\l\+\zs:', !0)
  if len(fragments) <= 1
    echoerr 'Unexpected a:incomplete_fakepath:' string(a:incomplete_fakepath)
    throw 'metarw:qiita#e1'
  endif

  let _.scheme = fragments[0]

  let path_fragments = split(fragments[1], '?', !0)
  " parse option parameter
  if len(path_fragments) == 2
    call extend(_.options, s:parse_options(path_fragments[1]), 'force')
    let fragments[1] = path_fragments[0]
  elseif len(path_fragments) >= 3
    echoerr 'path is invalid'
    let _.mode = ''
    return _
  endif

  if empty(fragments[1])
    let _.mode = 'write_new'
    let _.path = ''
  else
    let fragments = [fragments[0]] + split(fragments[1], '[\/]', !0)

    if len(fragments) == 3
      if fragments[1] == "items"
        let _.mode = 'items'
        let _.path = fragments[2]
      elseif fragments[1] == "users"
        let _.mode = 'users'
        let _.path = fragments[2]
      endif
    endif
  endif

  return _
endfunction " }}}

let &cpo = s:save_cpo
unlet s:save_cpo
