Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# The initialization script loads the Module's private data into a global
# variable so that it is available to all nested modules and so that it 
# can be easily overridden by the user at run-time.
# ---------------------------------------------------------------------------
$Module = $ExecutionContext.SessionState.Module
if (! $Module) {
	Throw ( New-Object System.InvalidOperationException `
		"An active module was not found!")
}
$Global:ModuleSettings = $Module.PrivateData.ModuleSettings