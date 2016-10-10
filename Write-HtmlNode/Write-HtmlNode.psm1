Set-StrictMode -Version Latest

function Write-HtmlNode($node, $indent = '', [switch]$excludeAttributes, [switch]$excludeEmptyElements, [switch]$excludeComments) {
    if ($excludeEmptyElements -and $node.nodeName -ne '#text' -and $node.nodeName -ne '#comment' -and $node.canHaveChildren -eq $false) {
        return
    }
    if ($excludeComments -and $node.nodeName -eq '#comment') {
        return
    }

    Write-Host $indent -NoNewline
    if ($node.nodeName -eq '#text') {
        Write-Host $node.nodeValue -ForegroundColor White
        return
    } elseif ($node.nodeName -eq '#comment') {
        Write-Host $node.OuterHtml -ForegroundColor DarkGreen
        return
    }
    Write-Host '<' -NoNewline -ForegroundColor Gray
    Write-Host $node.nodeName -NoNewline -ForegroundColor Blue
    if ($excludeAttributes -eq $false) {
        foreach ($attr in ($node.attributes | ? { $_.Specified })) {
            Write-Host ' ' -NoNewline
            Write-Host $attr.name -NoNewline -ForegroundColor Magenta
            Write-Host '="' -NoNewline -ForegroundColor Gray
            Write-Host $attr.value -NoNewline -ForegroundColor Yellow
            Write-Host '"' -NoNewline -ForegroundColor Gray
        }
    }
    if ($node.canHaveChildren -eq $false) {
        Write-Host ' />' -ForegroundColor Gray
        return
    }
    Write-Host '>' -ForegroundColor Gray
    $child = $node.firstChild
    $childIndent = $indent + '  '
    while ($child -ne $null) {
        write-htmlNode $child $childIndent -excludeAttributes:$excludeAttributes -excludeEmptyElements:$excludeEmptyElements -excludeComments:$excludeComments
        $child = $child.nextSibling
    }
    Write-Host $indent -NoNewline
    Write-Host '</' -NoNewline -ForegroundColor Gray
    Write-Host $node.nodeName -NoNewline -ForegroundColor Blue
    Write-Host '>' -ForegroundColor Gray
<#
.SYNOPSIS
    Writes the given HTML node with color
.PARAMETER node
    An HTML node, probably from (Invoke-WebRequest $url).ParsedHtml.documentElement
.PARAMETER indent
    How much of an indent to add before the first node
.PARAMETER excludeAttributes
    Whether to display attributes of the elements
.PARAMETER excludeEmptyElements
    Whether to display elements that cannot have any content
.PARAMETER excludeComments
    Whether to display the HTML comments
#>
}

Export-ModuleMember Write-HtmlNode