function global:prompt {
    $loc = $executionContext.SessionState.Path.CurrentLocation
    $osc7 = "$([char]27)]7;file://${env:COMPUTERNAME}/$($loc.Path.Replace('\','/'))$([char]27)\"
    "${osc7}PS $loc$('>' * ($nestedPromptLevel + 1)) "
}
