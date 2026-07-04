# E-Signature Package

Salesforce package for preparing PDF signature fields, sending a public signing link, collecting signer input, and finalizing the signed PDF through Power Automate and Azure.

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
