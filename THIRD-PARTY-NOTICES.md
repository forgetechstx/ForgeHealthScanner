# Dependencies and licensing

ForgeHealthScanner source is MIT licensed. The supplied Forge Technologies splash artwork and project icon are embedded in the native executable.

The application uses Windows and .NET Framework assemblies including Windows Forms, Drawing, Management, Web Extensions and the C# runtime binder. Health checks use the Windows registry, transaction APIs, WMI, COM and event logs. Optional actions use Defender, registry export, the printer subsystem and Windows Settings. Windows supplies these components.

Build and verification use the Windows .NET Framework C# compiler and Windows PowerShell. The native build has no NuGet or npm packages to restore. GitHub Actions are pinned by commit. The CycloneDX SBOM lists project inputs, the executable and referenced system assemblies.
