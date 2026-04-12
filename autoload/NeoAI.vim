" Vim autoload functions for NeoAI

function! NeoAI#Open(...) abort
    let l:mode = get(a:, 1, 'float')
    execute 'NeoAIOpen ' . l:mode
endfunction

function! NeoAI#Close() abort
    NeoAIClose
endfunction

function! NeoAI#Send(...) abort
    if a:0 > 0
        execute 'NeoAISend ' . join(a:000, ' ')
    endif
endfunction

function! NeoAI#New(...) abort
    if a:0 > 0
        execute 'NeoAINew ' . a:1
    else
        NeoAINew
    endif
endfunction

function! NeoAI#List() abort
    NeoAIList
endfunction

function! NeoAI#Switch(session_id) abort
    execute 'NeoAISwitch ' . a:session_id
endfunction

function! NeoAI#Export(...) abort
    if a:0 > 0
        execute 'NeoAIExport ' . a:1
    else
        NeoAIExport
    endif
endfunction

function! NeoAI#Import(...) abort
    if a:0 > 0
        execute 'NeoAIImport ' . a:1
    else
        NeoAIImport
    endif
endfunction

function! NeoAI#Mode(mode) abort
    execute 'NeoAIMode ' . a:mode
endfunction

function! NeoAI#Stats() abort
    NeoAIStats
endfunction

function! NeoAI#Setup(config) abort
    lua require('NeoAI').setup(vim.fn.eval('a:config'))
endfunction
