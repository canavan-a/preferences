#SuspendExempt true        ; This ensures the hotkey below will ALWAYS work.
F12::
{
    Suspend(-1) ; Toggle the suspension state

    if (A_IsSuspended)  ; Check the built-in variable: 1 if suspended, 0 otherwise
    {
        ; Script is now suspended (stopped)
        MsgBox("Hotkeys STOPPED (Suspended). Typing is normal.", "Script Status", 64) ; 64 = Information Icon
    }
    else
    {
        ; Script is now running (started)
        MsgBox("Hotkeys STARTED (Running). Custom keys are active.", "Script Status", 64)
    }
}
#SuspendExempt false       ; Stops exempting hotkeys.


!q::Send("{Esc}")

; Original Alt mappings
!h::Send("{Left}")
!l::Send("{Right}")
!j::Send("{Down}")
!k::Send("{Up}")

!y::Send("^" "{Left}")
!o::Send("^" "{Right}")

!u::Send("{PgDn}")
!i::Send("{PgUp}")

; Alt + Shift mappings
!+h::Send("+{Left}")
!+l::Send("+{Right}")
!+j::Send("+{Down}")
!+k::Send("+{Up}")

!+y::Send("^+{Left}")
!+o::Send("^+{Right}")

!+u::Send("+{PgDn}")
!+i::Send("+{PgUp}")

!c::Send("^c")
!v::Send("^v")
!x::Send("^x")
!s::Send("^s")
!z::Send("^z")
!f::Send("^f")
!a::Send("^a")

; unbind my arrow keys
Left::Return
Right::Return
Up::Return
Down::Return

; command to backspace
![::Send("{Backspace}")
!]::Send("^{Backspace}")


; The #HotIf directive creates the 'conditional' third key (Alt)
; This means all hotkeys below will ONLY be active when Alt is held down.
#HotIf GetKeyState("Alt", "P")

; --- Left Hand Home Row (A, S, D, F, G) -> (1, 2, 3, 4, 5) ---
Space & a::
{
    Send("1")
}

Space & s::
{
    Send("2")
}

Space & d::
{
    Send("3")
}

Space & f::
{
    Send("4")
}

Space & g::
{
    Send("5")
}

; --- Right Hand Home Row (H, J, K, L) -> (6, 7, 8, 9) ---
Space & h::
{
    Send("6")
}

Space & j::
{
    Send("7")
}

Space & k::
{
    Send("8")
}

Space & l::
{
    Send("9")
}

; You could also map the semicolon (;) key to 0
Space & `;::
{
    Send("0")
}

Space & '::
{
    Send("-")
}


; --- Left Hand Top Row (qwert) -> (!@#$%) ---

Space & CapsLock::
{
    Send("``")
}

Space & Tab::
{
    Send("~")
}

Space & q::
{
    Send("{!}")
}

Space & w::
{
    Send("@")
}

Space & e::
{
    Send("{#}")
}

Space & r::
{
    Send("$")
}

Space & t::
{
    Send("%")
}

; --- Right Hand Home Row (yuiop) -> (&*()_+) 
Space & y::
{
    Send("{^}")
}

Space & u::
{
    Send("&")
}

Space & i::
{
    Send("*")
}

Space & o::
{
    Send("(")
}

Space & p::
{
    Send(")")
}
Space & [::
{
    Send("_")
}


; This final #HotIf turns off the condition for any hotkeys defined afterward.
#HotIf

