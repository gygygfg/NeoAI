" Vim autoload functions for NeoAI

function! NeoAI#Open(...) abort
    let l:mode = get(a:, 1, '')
    execute 'NeoAIOpen ' . l:mode
endfunction

function! NeoAI#Close() abort
    NeoAIClose
endfunction

function! NeoAI#Chat(...) abort
    execute 'NeoAIChat'
endfunction

function! NeoAI#Tree() abort
    execute 'NeoAITree'
endfunction

function! NeoAI#Keymaps() abort
    NeoAIKeymaps
endfunction

function! NeoAI#ChatStatus() abort
    NeoAIChatStatus
endfunction

function! NeoAI#Test(...) abort
    if a:0 > 0
        execute 'NeoAITest ' . join(a:000, ' ')
    else
        NeoAITest
    endif
endfunction

function! NeoAI#Setup(config) abort
    lua require('NeoAI').setup(vim.fn.eval('a:config'))
endfunction
