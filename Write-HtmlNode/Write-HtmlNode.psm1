Set-StrictMode -Version Latest

function Write-HtmlNode($node, $indent = '', [switch]$excludeAttributes, [switch]$excludeEmptyElements, [switch]$excludeComments) {
    if ($excludeEmptyElements -and $node.nodeName -ne '#text' -and $node.nodeName -ne '#comment' -and $node.canHaveChildren -eq $false) {
        return
    }
    if ($excludeComments -and $node.nodeName -eq '#comment') {
        return
    }

    Write-Output $indent -NoNewline
    if ($node.nodeName -eq '#text') {
        Write-Output $node.nodeValue -ForegroundColor White
        return
    }
    elseif ($node.nodeName -eq '#comment') {
        Write-Output $node.OuterHtml -ForegroundColor DarkGreen
        return
    }
    Write-Output '<' -NoNewline -ForegroundColor Gray
    Write-Output $node.nodeName -NoNewline -ForegroundColor Blue
    if ($excludeAttributes -eq $false) {
        foreach ($attr in ($node.attributes | Where-Object { $_.Specified })) {
            Write-Output ' ' -NoNewline
            Write-Output $attr.name -NoNewline -ForegroundColor Magenta
            Write-Output '="' -NoNewline -ForegroundColor Gray
            Write-Output $attr.value -NoNewline -ForegroundColor Yellow
            Write-Output '"' -NoNewline -ForegroundColor Gray
        }
    }
    if ($node.canHaveChildren -eq $false) {
        Write-Output ' />' -ForegroundColor Gray
        return
    }
    Write-Output '>' -ForegroundColor Gray
    $child = $node.firstChild
    $childIndent = $indent + '  '
    while ($null -ne $child) {
        write-htmlNode $child $childIndent -excludeAttributes:$excludeAttributes -excludeEmptyElements:$excludeEmptyElements -excludeComments:$excludeComments
        $child = $child.nextSibling
    }
    Write-Output $indent -NoNewline
    Write-Output '</' -NoNewline -ForegroundColor Gray
    Write-Output $node.nodeName -NoNewline -ForegroundColor Blue
    Write-Output '>' -ForegroundColor Gray
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