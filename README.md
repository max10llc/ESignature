# E-Signature Package

Salesforce package for preparing PDF signature fields, sending a public signing link, collecting signer input, and finalizing the signed PDF through Power Automate and Azure.

## Sandbox Development

Use this project for both development and releases. The `sandbox-development` Git branch starts from the verified sandbox deployment of production's e-signature metadata on October 5, 2026. The project's default org is `esig-sandbox`; commands below also name it explicitly.

In VS Code, choose **Terminal > Run Task** and select an `ESignature:` task to open the sandbox, retrieve metadata, validate changes, or deploy changes. Validation and deployment run the 14 e-signature test classes. Production deployments remain a separate, deliberate step.

For a new change, create a feature branch from this baseline, edit the local source, validate, and deploy to the sandbox. If changes are made directly in Salesforce Setup, retrieve them into the project and review the Git diff before committing. Retrieval can overwrite local edits to the same metadata, so commit or stash those edits first.

```powershell
git switch -c feature/my-esignature-change
sf project retrieve start --manifest manifest/sandbox-development.xml --target-org esig-sandbox
```

`manifest/sandbox-development.xml` includes the deployed package metadata and its record-page and cancel-action dependencies, but excludes the environment-specific custom metadata record. The Default record under `force-app` is a sanitized reference and is excluded by `.forceignore`. Its actual sandbox values are stored in the Git-ignored `.local/esig-sandbox/customMetadata/ESignature_Setting.Default.md-meta.xml`. Edit these values in the sandbox's Custom Metadata settings, or explicitly deploy that local settings file when a configuration change is intended. Keep production settings separate; retrieve and review the destination's values before a release. Do not copy sandbox URLs or org-specific IDs into production.

The baseline was deployed using the sandbox's `NoTestRun` option. After sandbox email deliverability was enabled on October 5, 2026, the full Apex run and sequential reruns produced 87 passing tests out of 90. The three remaining test methods have since been updated to use explicit system mode only for seeding or verifying restricted signing-URL and email-log fields. All 23 methods in the affected classes passed across sequential runs and targeted reruns. Application code, production metadata, and field permissions remain unchanged. Deployment-time testing initially returned `NO_SINGLE_MAIL_PERMISSION` errors, so the test-class updates were deployed with `NoTestRun` and verified separately. The development tasks still require tests to pass; email permission errors and record locks may require investigation if they recur.

The deleted-source fix was deployed to `esig-sandbox` on October 5, 2026 (deployment `0AfTI00000ErTDV0A3`), with all 94 tests passing across the 14 e-signature test classes.

The same six-component deleted-source fix was deployed to Production on October 5, 2026 (deployment `0AfTS000001ztQP0AY`), after production validation `0AfTS000001ztOn0AI` passed all 94 tests. The release contains the page controller and utility, the deletion handler and trigger, and their page/deletion regression tests. Existing envelope records and environment settings were not migrated or changed.

Deleting a Salesforce source file cancels its unsigned Draft, Sent, Viewed, and Error envelopes in the same transaction. The deletion trigger handles both envelope source references and legacy prepared-field references, and records a cancellation audit. Cached PDFs stop being served, and an already-open signing page rechecks envelope status before accepting a signature. Restoring the file does not reopen the canceled request; send a new request. Signing submission displays Signature Submitted while finalization is pending. Document Complete is shown only after a final file reference exists, and reopening a failed signed request displays a completion error.

## Salesforce Setup

1. Deploy the metadata in `force-app/main/default` using `manifest/package.xml`.
2. Assign `ESignature_Package_User` to internal users who create and send e-signature documents.
3. Assign `ESignature_Package_Guest_User` to the public Site Guest User used by the signing page.
4. Add the e-signature related lists to the page layouts that need process visibility:
   - `E-Signature Envelopes`
   - `E-Signature Fields`
   - `E-Signature Audit Events`
5. Add `ContentVersion.ESignature_File__c` and `ContentVersion.ESignature_Status__c` to the Files UI if users need to flag source PDFs and see source file status.

## Custom Metadata

Update `ESignature_Setting.Default` after deployment.

Required values:

- `Site_Base_URL__c`: public Salesforce Site URL, for example `https://domain.my.salesforce-sites.com/signatures`.
- `Finalizer_Mode__c`: `PowerAutomateAsync` for the current Azure/Power Automate finalizer.
- `Finalizer_Named_Credential__c`: named credential used by Salesforce to call the Power Automate HTTP trigger.
- `Finalizer_Callback_Secret__c`: strong shared secret used by Power Automate when it posts the finalizer result back to Salesforce.

Do not leave `Finalizer_Callback_Secret__c` blank. The callback endpoint fails closed when this value is missing.

Optional values:

- `Finalizer_Callback_URL__c`: override for the Salesforce callback URL. If blank, Salesforce builds it from `Site_Base_URL__c`.
- `Final_Pdf_Owner_Password__c`: owner password used by the Azure finalizer when protecting the completed PDF.
- PDF restriction fields: control editing, copying, and low quality printing behavior on the final PDF.

## Power Automate Setup

1. Import the Power Automate flow package.
2. Configure the flow's HTTP trigger URL in the Salesforce named credential referenced by `Finalizer_Named_Credential__c`.
3. Configure the flow to call the Azure PDF finalizer function.
4. Configure the flow's final callback step to POST to:

   `/services/apexrest/ESignature/v1/finalizer-callback`

5. Include the shared secret in one of these places:
   - Preferred header: `X-PDF-ESignature-Secret`
   - JSON body fallback: `callbackSecret` or `secret`

The secret must exactly match `ESignature_Setting.Default.Finalizer_Callback_Secret__c`.

## Azure Function Setup

1. Deploy the Azure PDF finalizer function.
2. Verify the Azure Function directly with a sample payload before wiring it into Power Automate.
3. Store the Function URL and key in Power Automate or a secure connector setting.
4. Confirm the Azure Function response includes:
   - `success`
   - `finalPdfBase64` or final file identifiers
   - `message`

## Smoke Test

The E-Signature Prepare Document screen component has an input-only Boolean, **Bypass E-Signature File Requirement** (`bypassESignatureFileRequirement`), which defaults to false. Set it to true to load and save placements for a PDF without selecting its `E-Signature File` checkbox. The file must still be a PDF, and the bypass does not change the checkbox. Pass the file's Content Document Id to the component; the supplied `Prepare_ESignature_Document` flow still selects only flagged files in its upstream lookup.

Finalized signature overlays include a blue underline and the signer's typed name with the recorded signing timestamp beneath it. The timestamp uses the same format and timezone as the final audit report: the envelope sender's Salesforce timezone, falling back to the running user's timezone when no sender is available. The caption sits at the bottom of the signature placement, with the full-size signature raised above it so the caption does not extend below the document's signature baseline. New typed and drawn captures align their ink to the bottom of the original canvas without resizing it; the PDF renderer bottom-aligns signature images two points above the blue line. Existing Name, Title, Date, and Initials fields retain their placement.

Run `node scripts/tests/signature-ink-alignment.cjs` to check signature capture padding and size preservation in local headless Chrome. Set `CHROME_PATH` if Chrome is installed outside the default Windows location.

1. Mark a source PDF ContentVersion as `E-Signature File`.
2. Create an e-signature envelope from Account, Opportunity, or Work Order.
3. Place signer fields on the PDF.
4. Send the envelope.
5. Open the public signing link as the signer.
6. Complete the signature fields and submit.
7. Confirm Salesforce shows:
   - Envelope status progresses to `Sent`, `Viewed`, `Finalizing`, then `Signed`.
   - Audit events are created.
   - Source and final files show `E-Signature Status = Completed`.
   - Final PDF is attached to the parent record.

## Security Notes

- Rotate `Finalizer_Callback_Secret__c` if it is ever shared outside Salesforce and Power Automate.
- Do not commit production callback secrets.
- Keep the public Site Guest User permission set limited to the Visualforce page, REST resources, and e-signature objects required for signing.
