# Encender, apagar o ver el estado de las VM del proyecto desde el PC.
# Requiere Azure CLI con sesión iniciada (az login).
#
#   .\infra\vms.ps1 estado
#   .\infra\vms.ps1 apagar            # las dos
#   .\infra\vms.ps1 encender lab-vm2  # solo una
#
# "apagar" DESASIGNA la VM: deja de cobrarse el cómputo (solo disco e IP).
# Apagar desde Ubuntu (sudo shutdown) NO desasigna y se sigue cobrando.
param(
    [Parameter(Mandatory)][ValidateSet("estado", "apagar", "encender")] [string]$accion,
    [string[]]$vms = @("ad-2026", "lab-vm2")
)
$env:Path = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;" + $env:Path
$env:AZURE_CORE_ONLY_SHOW_ERRORS = "1"
$grupo = "ad-2026_grupo"

switch ($accion) {
    "apagar"   { foreach ($vm in $vms) { Write-Host "Apagando (desasignando) $vm..."; az vm deallocate -g $grupo -n $vm --no-wait } }
    "encender" { foreach ($vm in $vms) { Write-Host "Encendiendo $vm...";             az vm start      -g $grupo -n $vm --no-wait } }
}
if ($accion -ne "estado") { Write-Host "Orden enviada; tarda 1-3 minutos. Consulte con: .\infra\vms.ps1 estado" }
az vm list -g $grupo -d --query "[?tags.proyecto=='laboratorio' || name=='ad-2026'].{vm:name, estado:powerState, ip:publicIps}" -o table
