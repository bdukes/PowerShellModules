Set-StrictMode -Version Latest

function Read-Choice {
  param(
    [string]$caption,
    [string]$message,
    [array]$choices,
    [int]$defaultChoiceIndex = -1
  );

  if ($choices[0] -is [string]) {
    $choices = $choices | % { New-Object System.Management.Automation.Host.ChoiceDescription $_ }
  }
  
  $answerIndex = $host.ui.PromptForChoice($caption, $message, $choices, $defaultChoiceIndex)

  return $choices[$answerIndex].Label
<#
.SYNOPSIS
    Prompts the user to pick a choice from a set of options
.DESCRIPTION
    Prompts the user to pick a choice from a set of options.  Based on http://scriptolog.blogspot.com/2007/09/make-choice.html
.PARAMETER caption
    The title of the prompt
.PARAMETER message
    The question being asked
.PARAMETER choices
    An array of choices.  These can be strings or System.Management.Automation.Host.ChoiceDescription objects.  Prepend a letter with an ampersand to indicate the choice's hotkey
.PARAMETER defaultChoiceIndex
    The zero-based index of the default choice
.OUTPUTS
    The text of the choice
#>
}

function Read-BooleanChoice {
  param(
    [string]$caption,
    [string]$message,
    [string]$trueLabel = '&Yes',
    [string]$trueHelp = '',
    [string]$falseLabel = '&No',
    [string]$falseHelp = '',
    [switch]$showFalseAsFirstOption,
    $defaultChoice = $null
  );

  $trueChoice = New-Object System.Management.Automation.Host.ChoiceDescription $trueLabel,$trueHelp
  $falseChoice = New-Object System.Management.Automation.Host.ChoiceDescription $falseLabel,$falseHelp
  $defaultChoiceIndex = -1
  if ($defaultChoice -ne $null) {
    $defaultChoiceIndex = 0
    if ($defaultChoice -eq $false -xor $showFalseAsFirstOption) {
      $defaultChoiceIndex = 1
    }
  }

  if ($showFalseAsFirstOption) {
    $choices = @($falseChoice,$trueChoice)
  } else {
    $choices = @($trueChoice,$falseChoice)
  }
  $answerLabel = Read-Choice $caption $message $choices $defaultChoiceIndex
  return $answerLabel -eq $trueLabel
<#
.SYNOPSIS
    Prompts the user between two choices
.DESCRIPTION
    Prompts the user to choose an answer to a yes-or-no question
.PARAMETER caption
    The title of the prompt
.PARAMETER trueLabel
    The label for the choice that evaluates as true.  Use an ampersand before the letter that should be the hotkey, e.g. '&Yes'
.PARAMETER trueHelp
    The help text for the choice that evaluates as true
.PARAMETER falseLabel
    The label for the choice that evaluates as false.  Use an ampersand before the letter that should be the hotkey, e.g. '&No'
.PARAMETER falseHelp
    The help text for the choice that evaluates as false
.PARAMETER showFalseAsFirstOption
    Whether to show the false choice first
.PARAMETER defaultChoice
    $true to default to the true choice, $false to default to the false choice, or $null to have no default
.OUTPUTS
    $true if the true choice was picked, otherwise $false
#>
}

Export-ModuleMember Read-Choice
Export-ModuleMember Read-BooleanChoice