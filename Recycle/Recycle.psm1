#Set-StrictMode -Version Latest

function Remove-ItemSafely {

    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsShouldProcess = $true, ConfirmImpact = 'Medium', SupportsTransactions = $true, HelpUri = 'http://go.microsoft.com/fwlink/?LinkID=113373')]
    param(
        [Parameter(ParameterSetName = 'Path', Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]
        ${Path},

        [Parameter(ParameterSetName = 'LiteralPath', Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('PSPath')]
        [string[]]
        ${LiteralPath},

        [string]
        ${Filter},

        [string[]]
        ${Include},

        [string[]]
        ${Exclude},

        [switch]
        ${Recurse},

        [switch]
        ${Force},

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [pscredential]
        [System.Management.Automation.CredentialAttribute()]
        ${Credential},

        [switch]
        $DeletePermanently)


    begin {
        try {
            $outBuffer = $null
            if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
                $PSBoundParameters['OutBuffer'] = 1
            }
            if ($DeletePermanently -or @($PSBoundParameters.Keys | Where-Object { @('Filter', 'Include', 'Exclude', 'Recurse', 'Force', 'Credential') -contains $_ }).Count -ge 1) {
                if ($PSBoundParameters['DeletePermanently']) {
                    $PSBoundParameters.Remove('DeletePermanently') | Out-Null
                }

                $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Management\Remove-Item', [System.Management.Automation.CommandTypes]::Cmdlet)
                $scriptCmd = { & $wrappedCmd @PSBoundParameters }
            }
            else {
                $scriptCmd = { & recycleItem @PSBoundParameters }
            }

            $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            $steppablePipeline.Begin($PSCmdlet)
        }
        catch {
            throw
        }
    }

    process {
        try {
            $steppablePipeline.Process($_)
        }
        catch {
            throw
        }
    }

    end {
        try {
            $steppablePipeline.End()
        }
        catch {
            throw
        }
    }
    <#

.ForwardHelpTargetName Microsoft.PowerShell.Management\Remove-Item
.ForwardHelpCategory Cmdlet

#>

}

function recycleItem {
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsShouldProcess = $true, ConfirmImpact = 'Medium', SupportsTransactions = $true, HelpUri = 'http://go.microsoft.com/fwlink/?LinkID=113373')]
    param(
        [Parameter(ParameterSetName = 'Path', Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]
        ${Path},

        [Parameter(ParameterSetName = 'LiteralPath', Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('PSPath')]
        [string[]]
        ${LiteralPath})

    process {
        try {
            if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
                $items = @(Get-Item -LiteralPath:$PSBoundParameters['LiteralPath'])
            }
            else {
                $items = @(Get-Item -Path:$PSBoundParameters['Path'])
            }

            foreach ($item in $items) {
                if ($PSCmdlet.ShouldProcess($item)) {
                    $directoryPath = Split-Path $item -Parent

                    $shell = New-Object -ComObject "Shell.Application"
                    $shellFolder = $shell.Namespace($directoryPath)
                    $shellItem = $shellFolder.ParseName($item.Name)
                    $shellItem.InvokeVerb("delete")
                }
            }
        }
        catch {
            throw
        }
    }
}

#Credit for this approach: https://jdhitsolutions.com/blog/powershell/7024/managing-the-recycle-bin-with-powershell/
function Restore-Item {
    [CmdletBinding(DefaultParameterSetName = 'ManualSelection', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Position = 0, Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [String]
        $OriginalPath,

        [Parameter(Position = 1)]
        [Alias('Force')]
        [Switch]
        $Overwrite,

        [Parameter(Position = 2, ParameterSetName = 'ManualSelection')]
        [ValidateSet('Application', 'GetFolder', 'GetLink', 'IsBrowsable', 'IsFileSystem', 'IsFolder', 'IsLink', 'ModifyDate', 'Name', 'Parent', 'Path', 'Size', 'Type')]
        [Alias('Criteria', 'Property')]
        [String]
        $SelectionCriteria = 'ModifyDate',

        [Parameter(Position = 3, ParameterSetName = 'ManuelSelection')]
        [Alias('Desc')]
        [Switch]
        $Descending,

        [Parameter(Position = 2, ParameterSetName = 'Selector')]
        [Alias('Selector', 'Script', 'Lambda', 'Filter')]
        [ValidateNotNull()]
        [ScriptBlock]
        $SelectorScript
    )

    if ((Test-Path $OriginalPath) -and -not $Overwrite) {
        if ((Get-Item $OriginalPath) -is [System.IO.DirectoryInfo]) {
            Write-Error "Directory already exists and -Overwrite is not specified"
        }
        else {
            Write-Error "File already exists and -Overwrite is not specified"
        }
    }
    else {
        $RecycleBinItems = @() + (New-Object -com shell.application).Namespace(10).Items()
        $FoundItems = @()

        foreach ($Item in $RecycleBinItems) {
            if ($Item.GetFolder.Title -eq $OriginalPath) {
                $FoundItems += $Item
                Write-Verbose "Found $($Item.path)"
            }
        }
        if ($FoundItems.Length -eq 0) {
            Write-Error "No item in recycle bin with the specified path found"
        }
        else {
            if ($FoundItems.Length -gt 1) {
                if ($PSCmdlet.ParameterSetName -eq 'Selector') {
                    $SelectedItem = Invoke-Command $SelectorScript -ArgumentList $FoundItems
                }
                else {
                    $SelectedItem = $FoundItems | Sort-Object $SelectionCriteria -Descending:$Descending | Select-Object -First 1
                }
            }
            else {
                $SelectedItem = $FoundItems[0]
            }

            if ($SelectedItem) {
                #            This does not seem to work, so I am doing it manually
                #            Maybe someone can get this to work (although I don't see an advantage over the current method)
                #            (New-Object -ComObject "Shell.Application").Namespace($BinItems[0].Path).Self().InvokeVerb("Restore")
                if ($Overwrite -or $PSBoundParameters['Force']) {
                    Remove-ItemSafely $SelectedItem.Path
                }
                Move-Item $SelectedItem.Path $OriginalPath
            }
            else {
                Write-Error "No item with the specified criteria found"
            }

        }
    }

    <#
.SYNOPSIS
    Restores a file from the Recycle Bin.
.DESCRIPTION
    Finds the item(s) in the Recycle Bin with the given path, selects one based on the given selector (default is newest), and restores it to the original location.
.PARAMETER OriginalPath
    The original path to the file to restore.
.PARAMETER Overwrite
    Whether to overwrite the file at the path if it exists.
.PARAMETER SelectionCriteria
    How to sort the items to find which to restore.
.PARAMETER Descending
    Whether the SelectionCriteria sort should be descending or ascending.
.PARAMETER SelectorScript
    A script block which determines which item to restore.
#>
}

Export-ModuleMember -Function Remove-ItemSafely
Export-ModuleMember -Function Restore-Item
