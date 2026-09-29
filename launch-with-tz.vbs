' usage: wscript launch-with-tz.vbs <TZ> <exe> [args...]
' Started by start-app.ps1 through Invoke-CommandInDesktopPackage -PreventBreakaway, so <exe> runs
' inside the app's package container with TZ in its environment.
Set a = WScript.Arguments
Set sh = CreateObject("WScript.Shell")
sh.Environment("PROCESS")("TZ") = a(0)
cmd = """" & a(1) & """"
For i = 2 To a.Count - 1
  If InStr(a(i), " ") > 0 Then cmd = cmd & " """ & a(i) & """" Else cmd = cmd & " " & a(i)
Next
sh.Run cmd, 1, False
