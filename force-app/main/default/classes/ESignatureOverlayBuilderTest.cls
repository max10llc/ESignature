@IsTest
private class ESignatureOverlayBuilderTest {
    @IsTest
    static void buildsOverlayForExplicitCompletedFields() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Signed',
            Signer_Name__c = 'Derek Hawley',
            Signer_Title__c = 'President',
            Signed_At__c = DateTime.newInstanceGmt(2026, 6, 23, 15, 0, 0)
        );
        insert env;

        insert new List<ESignature_Field__c>{
            field(env.Id, 'Signature', 'Derek Hawley', 1, 100, 300, 160, 30, 1),
            field(env.Id, 'Name', 'Derek Hawley', 1, 100, 260, 160, 18, 2),
            field(env.Id, 'Title', 'President', 1, 100, 240, 160, 18, 3),
            field(env.Id, 'Date', '6/23/2026', 1, 100, 220, 160, 18, 4)
        };

        List<Map<String, Object>> payloads = ESignatureOverlayBuilder.buildOverlayPayloads(env.Id);
        System.assertEquals(1, payloads.size(), 'All explicit fields were on page 1, so only one overlay should be built.');
        System.assertEquals(1, Integer.valueOf(String.valueOf(payloads[0].get('pageNumber'))));
        System.assertEquals(612, Integer.valueOf(String.valueOf(payloads[0].get('pageWidth'))));
        System.assertNotEquals(null, payloads[0].get('overlayPdfBase64'));

        String pdfText = EncodingUtil.base64Decode((String) payloads[0].get('overlayPdfBase64')).toString();
        System.assert(pdfText.startsWith('%PDF-1.4'), 'Overlay output should be a PDF.');
        System.assert(pdfText.contains('/Helvetica-Oblique'), 'Signature overlay should use an Adobe watermark-safe PDF font.');
        System.assert(pdfText.contains('Derek Hawley'), 'Overlay should contain the signer name/signature text.');
        System.assert(pdfText.contains('President'), 'Overlay should contain the title text.');
        System.assert(pdfText.contains('6/23/2026'), 'Overlay should contain the date text.');
        System.assert(
            pdfText.contains('145.68 264.5 Td (Derek Hawley)'),
            'Name overlay text should be centered within its saved field bounds.'
        );

        Map<String, Object> debugInfo = ESignatureOverlayBuilder.buildOverlayDebugInfo(payloads);
        System.assertEquals(1, Integer.valueOf(String.valueOf(debugInfo.get('stampOverlayCount'))));
        System.assertEquals('1', (String) debugInfo.get('stampOverlayPagesText'));
    }

    @IsTest
    static void synthesizesMissingIdentityFieldsNearSignature() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Signed',
            Signer_Name__c = 'Derek Hawley',
            Signer_Title__c = 'President',
            Signed_At__c = DateTime.newInstanceGmt(2026, 6, 23, 15, 0, 0)
        );
        insert env;

        insert field(env.Id, 'Signature', 'Derek Hawley', 1, 100, 300, 160, 30, 1);

        List<Map<String, Object>> payloads = ESignatureOverlayBuilder.buildOverlayPayloads(env.Id);
        System.assertEquals(1, payloads.size(), 'Synthetic identity values should be added to the same signature page.');

        String pdfText = EncodingUtil.base64Decode((String) payloads[0].get('overlayPdfBase64')).toString();
        System.assert(pdfText.contains('Derek Hawley'), 'Overlay should include signature/name text.');
        System.assert(pdfText.contains('President'), 'Overlay should synthesize title when no explicit title field exists.');
        System.assert(pdfText.contains('6/23/2026'), 'Overlay should synthesize signing date when no explicit date field exists.');
    }

    @IsTest
    static void embedsSignatureImageWhenAvailable() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Signed',
            Signer_Name__c = 'Derek Hawley',
            Signer_Title__c = 'President',
            Signed_At__c = DateTime.newInstanceGmt(2026, 6, 23, 15, 0, 0),
            Signature_Image_Data_Url__c = 'data:image/jpeg;base64,' + tinyJpegBase64()
        );
        insert env;

        insert new List<ESignature_Field__c>{
            field(env.Id, 'Signature', 'Derek Hawley', 1, 100, 300, 180, 36, 1),
            field(env.Id, 'Name', 'Derek Hawley', 1, 100, 260, 160, 18, 2),
            field(env.Id, 'Title', 'President', 1, 100, 240, 160, 18, 3),
            field(env.Id, 'Date', '6/23/2026', 1, 100, 220, 160, 18, 4)
        };

        List<Map<String, Object>> payloads = ESignatureOverlayBuilder.buildOverlayPayloads(env.Id);

        String pdfText = EncodingUtil.base64Decode((String) payloads[0].get('overlayPdfBase64')).toString();
        System.assert(pdfText.contains('/Subtype /Image'), 'Overlay should embed the captured signature image.');
        System.assert(pdfText.contains('/DCTDecode'), 'Captured signature image should be embedded as a JPEG XObject.');
        System.assert(pdfText.contains('/Sig1 Do'), 'Signature field should draw the embedded signature image.');
        System.assert(pdfText.contains('/BM /Multiply'), 'Signature image overlay should make the JPEG white background visually transparent.');
        System.assert(pdfText.contains('/SignatureMultiply gs'), 'Signature image draw should use the transparent blend mode.');
    }

    @IsTest
    static void embedsInitialsImageStoredOnInitialsField() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Signed',
            Signer_Name__c = 'Derek Hawley',
            Signed_At__c = DateTime.newInstanceGmt(2026, 6, 23, 15, 0, 0)
        );
        insert env;

        insert field(env.Id, 'Initials', 'data:image/jpeg;base64,' + tinyJpegBase64(), 1, 100, 300, 80, 22, 1);

        List<Map<String, Object>> payloads = ESignatureOverlayBuilder.buildOverlayPayloads(env.Id);

        String pdfText = EncodingUtil.base64Decode((String) payloads[0].get('overlayPdfBase64')).toString();
        System.assert(pdfText.contains('/Subtype /Image'), 'Overlay should embed the captured initials image.');
        System.assert(pdfText.contains('/Init1 Do'), 'Initials field should draw its own embedded image.');
        System.assert(!pdfText.contains('data:image/jpeg;base64'), 'Initials image data should not be rendered as visible text.');
    }

    @IsTest
    static void rendersCheckedCheckboxAsCheckmarkOnly() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Signed',
            Signer_Name__c = 'Derek Hawley',
            Signed_At__c = DateTime.newInstanceGmt(2026, 6, 23, 15, 0, 0)
        );
        insert env;

        insert field(env.Id, 'Checkbox', 'true', 1, 100, 220, 18, 18, 1);

        List<Map<String, Object>> payloads = ESignatureOverlayBuilder.buildOverlayPayloads(env.Id);
        System.assertEquals(1, payloads.size(), 'Checked checkbox should create a one-page overlay.');

        String pdfText = EncodingUtil.base64Decode((String) payloads[0].get('overlayPdfBase64')).toString();
        System.assert(pdfText.contains(' m '), 'Checked checkbox should draw a checkmark path.');
        System.assert(pdfText.contains('105.16 229.24 m'), 'Checked checkbox mark should be centered in the field.');
        System.assert(!pdfText.contains(' re S Q'), 'Checked checkbox should not draw a surrounding checkbox rectangle.');
    }

    private static ESignature_Field__c field(
        Id envelopeId,
        String typeValue,
        String value,
        Integer pageNumber,
        Decimal x,
        Decimal y,
        Decimal width,
        Decimal height,
        Decimal sequence
    ) {
        return new ESignature_Field__c(
            Envelope__c = envelopeId,
            Field_Type__c = typeValue,
            Label__c = typeValue,
            Completed__c = true,
            Value__c = value,
            Page_Number__c = pageNumber,
            Pdf_X__c = x,
            Pdf_Y__c = y,
            Pdf_Width__c = width,
            Pdf_Height__c = height,
            Page_Width_Points__c = 612,
            Page_Height_Points__c = 792,
            Sequence__c = sequence
        );
    }

    private static String tinyJpegBase64() {
        return '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////'
            + '2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAA'
            + 'AAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAqf/'
            + 'xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/ASP/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/ASP/xAAUEAEAAAAAAAAAAAAA'
            + 'AAAAAAAA/9oACAEBAAY/Al//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IV//2gAMAwEAAgADAAAAEP/EABQRAQAAAAAAAAAAAA'
            + 'AAAAAAAAABD/2gAIAQMBAT8QH//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8QH//EABQQAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8QH//Z';
    }
}
