param([Parameter(Mandatory=$true)][string]$ScriptPath)

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'bash'
$psi.Arguments = "`"$ScriptPath`""
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$stdinText = [Console]::In.ReadToEnd()

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi
$null = $proc.Start()

$proc.StandardInput.Write($stdinText)
$proc.StandardInput.Close()

$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

if ($stdout) { [Console]::Out.Write($stdout) }
if ($stderr) { [Console]::Error.Write($stderr) }

exit $proc.ExitCode
