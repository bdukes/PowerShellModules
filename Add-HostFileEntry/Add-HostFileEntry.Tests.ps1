Import-Module $PsScriptRoot\..\AdministratorRole\AdministratorRole.psd1
Import-Module $PsScriptRoot\Add-HostFileEntry.psd1

Describe 'Add-HostFileEntry' {
    BeforeEach { $env:windir = 'TestDrive:' }

    Context 'No blank line at end of hosts file' {

        Mock -ModuleName Add-HostFileEntry Assert-AdministratorRole {}
        mkdir TestDrive:\System32\drivers\etc
        Copy-Item $PsScriptRoot\fixtures\no-blank-at-end.hosts TestDrive:\System32\drivers\etc\hosts

        Add-HostFileEntry test.test

        It 'Adds host file entry' {
            'TestDrive:\System32\drivers\etc\hosts' | Should -FileContentMatch '^127\.0\.0\.1\s+test\.test$'
        }
    }

    Context 'Empty hosts file' {

        Mock -ModuleName Add-HostFileEntry Assert-AdministratorRole {}
        mkdir TestDrive:\System32\drivers\etc
        Copy-Item $PsScriptRoot\fixtures\empty.hosts TestDrive:\System32\drivers\etc\hosts

        Add-HostFileEntry test.test

        It 'Adds host file entry' {
            'TestDrive:\System32\drivers\etc\hosts' | Should -FileContentMatch '^127\.0\.0\.1\s+test\.test$'
        }
    }
}

Describe 'Remove-HostFileEntry' {
    BeforeEach { $env:windir = 'TestDrive:' }

    Context 'No blank line at end of hosts file' {

        Mock -ModuleName Add-HostFileEntry Assert-AdministratorRole {}
        mkdir TestDrive:\System32\drivers\etc
        Copy-Item $PsScriptRoot\fixtures\no-blank-at-end.hosts TestDrive:\System32\drivers\etc\hosts

        Remove-HostFileEntry example.example

        It 'Removes host file entry' {
            'TestDrive:\System32\drivers\etc\hosts' | Should -Not -FileContentMatch '^127\.0\.0\.1\s+example\.example$'
        }
    }

    Context 'Empty hosts file' {

        Mock -ModuleName Add-HostFileEntry Assert-AdministratorRole {}
        mkdir TestDrive:\System32\drivers\etc
        Copy-Item $PsScriptRoot\fixtures\empty.hosts TestDrive:\System32\drivers\etc\hosts

        Remove-HostFileEntry test.test

        It 'Leaves empty host file' {
            'TestDrive:\System32\drivers\etc\hosts' | Should -Not -FileContentMatchMultiline '.*'
        }
    }

    Context 'Three Hosts' {

        Mock -ModuleName Add-HostFileEntry Assert-AdministratorRole {}
        mkdir TestDrive:\System32\drivers\etc
        Copy-Item $PsScriptRoot\fixtures\three-hosts.hosts TestDrive:\System32\drivers\etc\hosts

        Remove-HostFileEntry two.example

        It 'Leaves two hosts' {
            'TestDrive:\System32\drivers\etc\hosts' | Should -Not -FileContentMatch '^127\.0\.0\.1\s+two\.example$'
            'TestDrive:\System32\drivers\etc\hosts' | Should -FileContentMatch '^127\.0\.0\.1\s+one\.example$'
            'TestDrive:\System32\drivers\etc\hosts' | Should -FileContentMatch '^127\.0\.0\.1\s+three\.example$'
        }
    }
}
