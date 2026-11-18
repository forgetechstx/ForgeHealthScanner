# Dependencies and licensing

Project source, embedded PowerShell/HTML/JavaScript and original icon: MIT; see LICENSE.
No third-party code packages, fonts, images, scripts or DLLs are bundled in the EXE.
The icon is an original geometric pulse drawing generated for this project.

Runtime dependencies are Windows system components: .NET Framework 4.x (including
System.Windows.Forms and System.Drawing), Windows PowerShell 5.1 / System.Management.Automation,
Windows registry/transaction APIs, CIM/WMI/COM and Windows modules. Microsoft Defender,
Storage, BitLocker and other optional system modules may be unavailable; checks
handle unsupported or inaccessible data. These system components are not relicensed
as MIT and are not redistributed. An existing browser displays the dashboard.

Build: Windows' .NET Framework C# compiler and PowerShell. Tests additionally use
Node.js 24.17.0 built-in modules only. No package manager dependency graph exists,
so npm/NuGet lockfiles would misrepresent this build. CI actions are pinned by SHA.
Windows runner images/system servicing vary; release manifests record actual
compiler, OS, PowerShell and referenced assembly versions for each build.

The CycloneDX SBOM inventories the application, its own source modules and the
referenced .NET system assemblies (required but not distributed). It does not
claim to enumerate every Windows component or browser transitive dependency.
