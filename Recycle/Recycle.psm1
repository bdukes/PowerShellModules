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

function Restore-RecycledItem {
    [CmdletBinding(DefaultParameterSetName = 'ManualSelection', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'ComObject', Mandatory, ValueFromPipeline)]
        [System.__ComObject]
        $ComObject,

        [Parameter(Position = 0, ParameterSetName = 'ManualSelection', Mandatory)]
        [Parameter(Position = 0, ParameterSetName = 'Selector', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]
        $OriginalPath,

        [Parameter(Position = 1, ParameterSetName = 'ManualSelection')]
        [ValidateSet('Application', 'GetFolder', 'GetLink', 'IsBrowsable', 'IsFileSystem', 'IsFolder', 'IsLink', 'ModifyDate', 'Name', 'Parent', 'Path', 'Size', 'Type')]
        [Alias('Criteria', 'Property')]
        [String]
        $SortingCriteria = 'ModifyDate',

        [Parameter(Position = 2, ParameterSetName = 'ManuelSelection')]
        [Alias('Desc')]
        [Switch]
        $Descending,

        [Parameter(Position = 1, ParameterSetName = 'Selector')]
        [Alias('Selector', 'Script', 'Lambda', 'Filter')]
        [ValidateNotNull()]
        [ScriptBlock]
        $SelectorScript,

        [Parameter(ParameterSetName = 'ManualSelection')]
        [Parameter(ParameterSetName = 'Selector')]
        [Parameter(ParameterSetName = 'ComObject')]
        [Switch]
        $Overwrite
    )

    process {
        if ($ComObject) {
            $FoundItem = $ComObject
            $OriginalPath = $ComObject.GetFolder.Title
        }

        if ((Test-Path $OriginalPath) -and -not $Overwrite) {
            if ((Get-Item $OriginalPath) -is [System.IO.DirectoryInfo]) {
                Write-Error "Directory already exists and -Overwrite is not specified"
            }
            else {
                Write-Error "File already exists and -Overwrite is not specified"
            }
        }
        else {
            if ($PSCmdlet.ParameterSetName -eq "ManualSelection" -or $PSCmdlet.ParameterSetName -eq "Selector") {
                $BoundParametersLessOverwrite = $PSBoundParameters
                if ($BoundParametersLessOverwrite.ContainsKey("Overwrite")) {
                    $BoundParametersLessOverwrite.Remove("Overwrite") | Out-Null
                }
                $FoundItem = Get-RecycledItem @PSBoundParameters -Top 1
            }

            if ($FoundItem) {
                # This does not seem to work, so I am doing it manually
                # Maybe someone can get this to work (although I don't see an advantage over the current method)
                #(New-Object -ComObject "Shell.Application").Namespace($BinItems[0].Path).Self().InvokeVerb("Restore")
                if ($Overwrite -or $PSBoundParameters['Force']) {
                    Remove-ItemSafely $OriginalPath
                }
                Move-Item $FoundItem.Path $OriginalPath
            }
            else {
                Write-Error "No item in recycle bin with the specified path found"
            }
        }

        return Get-Item $OriginalPath -ErrorAction SilentlyContinue
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
.PARAMETER SortingCriteria
    How to sort the items to find which to restore.
.PARAMETER Descending
    Whether the SortingCriteria sort should be descending or ascending.
.PARAMETER SelectorScript
    A script block which determines which item to restore.
.INPUTS
    System.__ComObject The result of calling Get-RecycledItem
.OUTPUTS
    System.Object Return the item that was restored.
.EXAMPLE
    Restore-Item "C:\TestFolder\TestFile.txt"
.EXAMPLE
    Restore-Item "C:\TestFolder\TestFile.txt" -SortingCriteria "Size" -Descending
.EXAMPLE
    Restore-Item "C:\TestFolder\TestFile.txt" -SelectorScript { $_.ModifyDate -eq '01.01.1970' }
.NOTES
    Credit for this approach: https://jdhitsolutions.com/blog/powershell/7024/managing-the-recycle-bin-with-powershell/
.NOTES
    Author: Kevin Holtkamp, kevinholtkamp26@gmail.com
    LastEdit: 09.07.2022
#>
}

function Get-RecycledItem {
    [CmdletBinding(DefaultParameterSetName = 'OriginalPath')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ParameterSetName = 'OriginalPath')]
        [String]
        $OriginalPath,

        [Parameter(Position = 1, ParameterSetName = 'OriginalPathRegex')]
        [String]
        $OriginalPathRegex,

        [Parameter(Position = 2)]
        [ValidateSet('Application', 'GetFolder', 'GetLink', 'IsBrowsable', 'IsFileSystem', 'IsFolder', 'IsLink', 'ModifyDate', 'Name', 'Parent', 'Path', 'Size', 'Type')]
        [Alias('Criteria', 'Property')]
        [String]
        $SortingCriteria = 'ModifyDate',

        [Parameter(Position = 3)]
        [Alias('Desc')]
        [Switch]
        $Descending,

        [Parameter(Position = 4)]
        [ValidateScript({ $_ -gt 0 })]
        [Int16]
        $Top,

        [Parameter(Position = 1)]
        [Alias('Selector', 'Script', 'Lambda', 'Filter')]
        [ValidateNotNull()]
        [ScriptBlock]
        $SelectorScript
    )

    process {
        $SelectedItems = @() + (New-Object -com shell.application).Namespace(10).Items()

        if ($OriginalPath) {
            $SelectedItems = $SelectedItems | Where-Object { $_.GetFolder.Title -eq $OriginalPath }
        }

        if ($OriginalPathRegex) {
            $SelectedItems = $SelectedItems | Where-Object { $_.GetFolder.Title -match $OriginalPathRegex }
        }

        if ($SelectorScript) {
            $SelectedItems = $SelectedItems | Where-Object { Invoke-Command $SelectorScript -ArgumentList $_ }
        }

        if ($SortingCriteria) {
            $SelectedItems = $SelectedItems | Sort-Object $SortingCriteria -Descending:$Descending
        }

        if ($Top) {
            $SelectedItems = $SelectedItems | Select-Object -First $Top
        }

        return $SelectedItems
    }
    <#
.SYNOPSIS
    Get all items from the recycle bin, optionally filtered by the parameters
.DESCRIPTION
    Get all items from the recycle bin, optionally filtered by the parameters
.PARAMETER OriginalPath
    Filters recycle bin items by their original path
.PARAMETER OriginalPathRegex
    Filters recycle bin items by their original path with a regex
.PARAMETER SortingCriteria
    Sort output by the specified criteria
.PARAMETER Descending
    Sort output descending instead of ascending
.PARAMETER Top
    Only get top n results
.PARAMETER SelectorScript
    Custom script to filter the results
.INPUTS
    System.String The OriginalPath to search for
.OUTPUTS
    System.__ComObject The recycle bin items
.EXAMPLE
    Get-RecycledItems -OriginalPath "C:\Users\Kevin\Testfile"
.EXAMPLE
    Get-RecycledItems -SortingCriteria "Size" -Descending -Top 5
.EXAMPLE
    Get-RecycledItems -SelectorScript { $_.IsFolder -eq $true }
.NOTES
    Author: Kevin Holtkamp, kevinholtkamp26@gmail.com
    LastEdit: 09.07.2022
#>
}

Export-ModuleMember -Function Get-RecycledItem
Export-ModuleMember -Function Remove-ItemSafely
Export-ModuleMember -Function Restore-RecycledItem
