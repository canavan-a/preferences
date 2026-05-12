#SuspendExempt true
F12::
{
    Suspend(-1)
    if (A_IsSuspended) {
        MsgBox("Hotkeys STOPPED (Suspended). Typing is normal.", "Script Status", 64)
    }
    else {
        MsgBox("Hotkeys STARTED (Running). Custom keys are active.", "Script Status", 64)
    }
}
#SuspendExempt false

<!q:: Send("{Esc}")
<!\:: Send("{Del}")

<!h:: Send("{Left}")
<!l:: Send("{Right}")
<!j:: Send("{Down}")
<!k:: Send("{Up}")

<!y:: Send("^{Left}")
<!o:: Send("^{Right}")

<!u:: Send("{PgDn}")
<!i:: Send("{PgUp}")

<!+h:: Send("+{Left}")
<!+l:: Send("+{Right}")
<!+j:: Send("+{Down}")
<!+k:: Send("+{Up}")

<!+y:: Send("^+{Left}")
<!+o:: Send("^+{Right}")

<!+u:: Send("+{PgDn}")
<!+i:: Send("+{PgUp}")

<!c:: Send("^c")
<!v:: Send("^v")
<!x:: Send("^x")
<!s:: Send("^s")
<!z:: Send("^z")
<!f:: Send("^f")
<!a:: Send("^a")
<!e:: Send("^e")
<!b:: Send("^b")
<!n:: Send("^n")
<!d:: Send("^d")

Left:: return
Right:: return
Up:: return
Down:: return

<!;:: Send("{Backspace}")
<!':: Send("^{Backspace}")

#HotIf GetKeyState("LAlt", "P")

Space & a:: Send("1")
Space & s:: Send("2")
Space & d:: Send("3")
Space & f:: Send("4")
Space & g:: Send("5")

Space & h:: Send("6")
Space & j:: Send("7")
Space & k:: Send("8")
Space & l:: Send("9")

Space & `;:: Send("0")
Space & ':: Send("-")

Space & CapsLock:: Send("``")
Space & Tab:: Send("~")

Space & q:: Send("{!}")
Space & w:: Send("@")
Space & e:: Send("{#}")
Space & r:: Send("$")
Space & t:: Send("%")

Space & y:: Send("{^}")
Space & u:: Send("&")
Space & i:: Send("*")
Space & o:: Send("(")
Space & p:: Send(")")
Space & SC1A:: Send("_")
Space & SC1B:: Send("{+}")
Space & Enter:: Send("=")

#HotIf