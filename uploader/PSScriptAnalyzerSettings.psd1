@{
    # Findings of these severities fail the build (see .gitlab-ci.yml, job uploader-lint).
    Severity     = @('Error', 'Warning')

    # Add a rule here only together with a written reason.
    ExcludeRules = @()

    Rules        = @{
        # The code must run on Windows PowerShell 5.1 and on PowerShell 7.
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace  = @{
            Enable = $true
        }
    }
}
