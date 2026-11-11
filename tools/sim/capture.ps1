# VS-12 — captura da área cliente da janela "Vox Engine" via GDI (padrão VS-11).
# Uso: powershell -File capture.ps1 -Out <arquivo.png>
param([string]$Out = "shot.png")

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public struct POINT { public int X; public int Y; }
public class U32 {
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
"@

$proc = Get-Process vox -ErrorAction SilentlyContinue
if ($null -eq $proc) { Write-Error "processo vox não encontrado"; exit 1 }
$h = $proc.MainWindowHandle
[U32]::ShowWindow($h, 9) | Out-Null
# HWND_TOPMOST sem mover/redimensionar: traz a janela à frente sem precisar de foreground
[U32]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0002) | Out-Null
Start-Sleep -Milliseconds 500
$rect = New-Object RECT
[U32]::GetClientRect($h, [ref]$rect) | Out-Null
$pt = New-Object POINT
[U32]::ClientToScreen($h, [ref]$pt) | Out-Null
$w = $rect.Right - $rect.Left
$hgt = $rect.Bottom - $rect.Top
Write-Output "cliente: ${w}x${hgt} em ($($pt.X),$($pt.Y))"

$bmp = New-Object System.Drawing.Bitmap($w, $hgt)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($pt.X, $pt.Y, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
# devolve a janela ao estado normal (remove TOPMOST)
[U32]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0001 -bor 0x0002) | Out-Null
$g.Dispose(); $bmp.Dispose()
Write-Output "salvo em $Out"
