' Launch the remote shutdown server without attaching to any console window,
' then wait for it so a scheduled task can track its lifetime and exit code.
' Used by install-remote.ps1 and the logon task, so the server is not killed
' when the window that started it closes.

Dim fso, sh, base, ps, cmd, rc
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

base = fso.GetParentFolderName(WScript.ScriptFullName)
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & ps & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\remote-server.ps1"""

rc = sh.Run(cmd, 0, True)
WScript.Quit rc
