$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$bin = Join-Path $root 'zapret-source\bin'
$winws = Join-Path $bin 'winws.exe'
$fake = Join-Path $bin 'ACTIVE_GAME_UDP.bin'
$targets = @('RainbowSix','RainbowSix_BE','UbisoftConnect','UbisoftGameLauncher','UbisoftGameLauncher64','upc')

if (-not (Test-Path $winws) -or -not (Test-Path $fake)) { Write-Host 'Не найдены файлы Zapret в zapret-source\bin.' -ForegroundColor Red; Read-Host 'Enter'; exit 1 }
$admin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    exit
}
$other = @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue)
$driverRunning = $false
foreach ($serviceName in @('WinDivert','WinDivert14')) {
    $state = (& (Join-Path $env:SystemRoot 'System32\sc.exe') query $serviceName 2>$null | Out-String)
    if ($LASTEXITCODE -eq 0 -and $state -match 'STATE\s*:\s*4\s+RUNNING') { $driverRunning = $true }
}
if ($other.Count -gt 0 -or $driverRunning) {
    Write-Host 'Обнаружен запущенный winws.exe/WinDivert. Профиль не стартовал, чтобы не мешать другой программе.' -ForegroundColor Yellow
    Write-Host 'Остановите текущий Zapret через его собственный интерфейс и запустите снова.'
    Read-Host 'Enter'; exit 2
}
Write-Host 'Game Filter для Siege: 1 UDP, 2 TCP+UDP, 3 TCP. Начните с UDP.'
$choice = Read-Host 'Режим [1]'
if ([string]::IsNullOrWhiteSpace($choice)) { $choice='1' }
if ($choice -notin @('1','2','3')) { Write-Host 'Неверный выбор.'; Read-Host 'Enter'; exit 3 }

# Flowseal Game Filter port range; omitting --ipset selects IPSet any.
$p='1024-65535'; $argsList=@()
if ($choice -in @('2','3')) { $argsList += "--wf-tcp=$p" }
if ($choice -in @('1','2')) { $argsList += "--wf-udp=$p" }
if ($choice -in @('2','3')) { $argsList += "--filter-tcp=$p"; $argsList += '--dpi-desync=syndata'; $argsList += '--dpi-desync-any-protocol=1'; $argsList += '--dpi-desync-cutoff=n4' }
if ($choice -eq '2') { $argsList += '--new' }
if ($choice -in @('1','2')) { $argsList += "--filter-udp=$p"; $argsList += '--dpi-desync=fake'; $argsList += '--dpi-desync-repeats=12'; $argsList += '--dpi-desync-any-protocol=1'; $argsList += ('--dpi-desync-fake-unknown-udp="' + $fake + '"'); $argsList += '--dpi-desync-cutoff=n2' }

$typeDef = @'
using System;
using System.Runtime.InteropServices;
namespace R6Zapret {
 public static class Job {
  [StructLayout(LayoutKind.Sequential)] struct Basic { public long A,B; public uint Flags; public UIntPtr Min,Max; public uint Active; public UIntPtr Affinity; public uint Priority,Scheduling; }
  [StructLayout(LayoutKind.Sequential)] struct Io { public ulong A,B,C,D,E,F; }
  [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic Basic; public Io Io; public UIntPtr A,B,C,D; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a,string n);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j,int c,ref Extended e,uint l);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  public static IntPtr Create() { IntPtr j=CreateJobObject(IntPtr.Zero,null); if(j==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); Extended e=new Extended(); e.Basic.Flags=0x2000; if(!SetInformationJobObject(j,9,ref e,(uint)Marshal.SizeOf(typeof(Extended)))) { int x=Marshal.GetLastWin32Error(); CloseHandle(j); throw new System.ComponentModel.Win32Exception(x); } return j; }
  public static void Assign(IntPtr j,IntPtr p) { if(!AssignProcessToJobObject(j,p)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
  public static void Close(IntPtr j) { if(j!=IntPtr.Zero) CloseHandle(j); }
 }
}
'@
$job=[IntPtr]::Zero; $proc=$null
try {
 Add-Type -TypeDefinition $typeDef -Language CSharp
 $job=[R6Zapret.Job]::Create()
 Write-Host 'Ожидание запуска Ubisoft Connect или Rainbow Six Siege. Ctrl+C останавливает профиль.'
 $started=$false
 while ($true) {
  $active=@(Get-Process -Name $targets -ErrorAction SilentlyContinue)
  if ($active.Count -gt 0) {
   if (-not $started) {
    $proc=Start-Process -FilePath $winws -ArgumentList $argsList -WorkingDirectory $bin -WindowStyle Hidden -PassThru
    [R6Zapret.Job]::Assign($job,$proc.Handle); $started=$true
    $modeNames = @{'1'='UDP';'2'='TCP+UDP';'3'='TCP'}; Write-Host ('Game Filter запущен: ' + $modeNames[$choice]) -ForegroundColor Green
   }
   if ($proc.HasExited) { Write-Host 'winws.exe завершился.' -ForegroundColor Red; break }
  } elseif ($started) { Write-Host 'Все целевые приложения закрыты; выключаю профиль.' -ForegroundColor Yellow; break }
  Start-Sleep -Seconds 3
 }
} catch {
 Write-Host ('Ошибка: ' + $_.Exception.Message) -ForegroundColor Red
 Read-Host 'Enter'
} finally {
 if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
 if ($job -ne [IntPtr]::Zero) { [R6Zapret.Job]::Close($job) }
}
