public without sharing class PDFESignatureOverlayBuilder {
    private static final Decimal DEFAULT_PAGE_WIDTH = 612;
    private static final Decimal DEFAULT_PAGE_HEIGHT = 792;

    public class OverlayPage {
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public Decimal pageWidth;
        @AuraEnabled public Decimal pageHeight;
        @AuraEnabled public String overlayPdfBase64;
    }

    public static List<Map<String, Object>> buildOverlayPayloads(Id envelopeId) {
        List<Map<String, Object>> output = new List<Map<String, Object>>();
        for (OverlayPage overlay : buildOverlayPages(envelopeId)) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('pageNumber', overlay.pageNumber);
            row.put('pageWidth', overlay.pageWidth);
            row.put('pageHeight', overlay.pageHeight);
            row.put('overlayPdfBase64', overlay.overlayPdfBase64);
            output.add(row);
        }
        return output;
    }

    public static List<OverlayPage> buildOverlayPages(Id envelopeId) {
        if (envelopeId == null) {
            return new List<OverlayPage>();
        }

        PDF_ESignature_Envelope__c env = loadEnvelope(envelopeId);
        List<PDF_ESignature_Field__c> fields = [
            SELECT Id, Field_Type__c, Label__c, Page_Number__c, Pdf_X__c, Pdf_Y__c,
                   Pdf_Width__c, Pdf_Height__c, Page_Width_Points__c, Page_Height_Points__c,
                   Value__c, Completed__c, Sequence__c
            FROM PDF_ESignature_Field__c
            WHERE Envelope__c = :envelopeId
            AND Completed__c = true
            ORDER BY Page_Number__c ASC, Sequence__c ASC, CreatedDate ASC
        ];
        fields = withSyntheticIdentityFields(fields, env);

        Map<Integer, List<PDF_ESignature_Field__c>> fieldsByPage = new Map<Integer, List<PDF_ESignature_Field__c>>();
        for (PDF_ESignature_Field__c field : fields) {
            if (String.isBlank(field.Value__c)) {
                continue;
            }
            Integer pageNumber = field.Page_Number__c == null ? 1 : Integer.valueOf(field.Page_Number__c);
            if (!fieldsByPage.containsKey(pageNumber)) {
                fieldsByPage.put(pageNumber, new List<PDF_ESignature_Field__c>());
            }
            fieldsByPage.get(pageNumber).add(field);
        }

        List<Integer> pageNumbers = new List<Integer>(fieldsByPage.keySet());
        pageNumbers.sort();

        List<OverlayPage> overlays = new List<OverlayPage>();
        for (Integer pageNumber : pageNumbers) {
            List<PDF_ESignature_Field__c> pageFields = fieldsByPage.get(pageNumber);
            if (pageFields == null || pageFields.isEmpty()) {
                continue;
            }
            Decimal pageWidth = firstNonNull(pageFields[0].Page_Width_Points__c, DEFAULT_PAGE_WIDTH);
            Decimal pageHeight = firstNonNull(pageFields[0].Page_Height_Points__c, DEFAULT_PAGE_HEIGHT);

            OverlayPage overlay = new OverlayPage();
            overlay.pageNumber = pageNumber;
            overlay.pageWidth = pageWidth;
            overlay.pageHeight = pageHeight;
            overlay.overlayPdfBase64 = EncodingUtil.base64Encode(buildSinglePageOverlayPdf(pageFields, pageWidth, pageHeight));
            overlays.add(overlay);
        }
        return overlays;
    }

    public static Map<String, Object> buildOverlayDebugInfo(List<Map<String, Object>> overlays) {
        List<Object> pages = new List<Object>();
        List<String> pageStrings = new List<String>();
        if (overlays != null) {
            for (Map<String, Object> overlay : overlays) {
                Object pageValue = overlay == null ? null : overlay.get('pageNumber');
                if (pageValue != null) {
                    pages.add(pageValue);
                    pageStrings.add(String.valueOf(pageValue));
                }
            }
        }
        return new Map<String, Object>{
            'stampOverlayCount' => overlays == null ? 0 : overlays.size(),
            'stampOverlayPages' => pages,
            'stampOverlayPagesText' => String.join(pageStrings, ',')
        };
    }

    private static PDF_ESignature_Envelope__c loadEnvelope(Id envelopeId) {
        List<PDF_ESignature_Envelope__c> rows = [
            SELECT Id, Signer_Name__c, Signer_Title__c, Signed_At__c
            FROM PDF_ESignature_Envelope__c
            WHERE Id = :envelopeId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static List<PDF_ESignature_Field__c> withSyntheticIdentityFields(List<PDF_ESignature_Field__c> fields, PDF_ESignature_Envelope__c env) {
        List<PDF_ESignature_Field__c> output = new List<PDF_ESignature_Field__c>();
        if (fields != null) {
            output.addAll(fields);
        }
        if (env == null || fields == null || fields.isEmpty()) {
            return output;
        }

        Set<String> explicitTypes = new Set<String>();
        PDF_ESignature_Field__c anchorSignature;
        for (PDF_ESignature_Field__c field : fields) {
            String typeValue = normalizeType(field.Field_Type__c);
            if (!String.isBlank(typeValue)) {
                explicitTypes.add(typeValue);
            }
            if (anchorSignature == null && typeValue == 'Signature' && !String.isBlank(field.Value__c)) {
                anchorSignature = field;
            }
        }
        if (anchorSignature == null) {
            return output;
        }

        Integer syntheticIndex = 0;
        if (!explicitTypes.contains('Name') && !String.isBlank(env.Signer_Name__c)) {
            syntheticIndex++;
            output.add(syntheticField(anchorSignature, 'Name', env.Signer_Name__c, syntheticIndex));
        }
        if (!explicitTypes.contains('Title') && !String.isBlank(env.Signer_Title__c)) {
            syntheticIndex++;
            output.add(syntheticField(anchorSignature, 'Title', env.Signer_Title__c, syntheticIndex));
        }
        if (!explicitTypes.contains('Date')) {
            syntheticIndex++;
            output.add(syntheticField(anchorSignature, 'Date', signedDateText(env.Signed_At__c), syntheticIndex));
        }
        return output;
    }

    private static PDF_ESignature_Field__c syntheticField(PDF_ESignature_Field__c anchor, String typeValue, String value, Integer index) {
        Decimal anchorX = firstNonNull(anchor.Pdf_X__c, 0);
        Decimal anchorY = firstNonNull(anchor.Pdf_Y__c, 0);
        Decimal anchorWidth = firstNonNull(anchor.Pdf_Width__c, 160);
        Decimal anchorHeight = firstNonNull(anchor.Pdf_Height__c, 24);
        Decimal pageHeight = firstNonNull(anchor.Page_Height_Points__c, DEFAULT_PAGE_HEIGHT);

        Decimal rowHeight = minDecimal(anchorHeight * 0.55, 14);
        if (rowHeight < 10) {
            rowHeight = 10;
        }
        Decimal gap = 2;
        Decimal y = anchorY - ((rowHeight + gap) * index);
        if (y < 4) {
            y = anchorY + anchorHeight + gap + ((rowHeight + gap) * (index - 1));
        }
        if (y + rowHeight > pageHeight - 4) {
            y = pageHeight - rowHeight - 4;
        }

        PDF_ESignature_Field__c field = new PDF_ESignature_Field__c();
        field.Field_Type__c = typeValue;
        field.Label__c = typeValue + ' (Auto)';
        field.Page_Number__c = anchor.Page_Number__c;
        field.Pdf_X__c = anchorX;
        field.Pdf_Y__c = y;
        field.Pdf_Width__c = maxDecimal(anchorWidth, 120);
        field.Pdf_Height__c = rowHeight;
        field.Page_Width_Points__c = anchor.Page_Width_Points__c;
        field.Page_Height_Points__c = anchor.Page_Height_Points__c;
        field.Value__c = value;
        field.Completed__c = true;
        Decimal anchorSequence = anchor.Sequence__c == null ? Decimal.valueOf('0') : anchor.Sequence__c;
        field.Sequence__c = anchorSequence + (Decimal.valueOf(String.valueOf(index)) / 100);
        return field;
    }

    private static Blob buildSinglePageOverlayPdf(List<PDF_ESignature_Field__c> fields, Decimal pageWidth, Decimal pageHeight) {
        String content = buildContentStream(fields);
        String pdf = buildPdfDocument(content, pageWidth, pageHeight);
        return Blob.valueOf(pdf);
    }

    private static String buildContentStream(List<PDF_ESignature_Field__c> fields) {
        List<String> lines = new List<String>();
        for (PDF_ESignature_Field__c field : fields) {
            String value = normalizeText(field.Value__c);
            if (String.isBlank(value)) {
                continue;
            }

            Decimal x = firstNonNull(field.Pdf_X__c, 0);
            Decimal y = firstNonNull(field.Pdf_Y__c, 0);
            Decimal width = firstNonNull(field.Pdf_Width__c, 120);
            Decimal height = firstNonNull(field.Pdf_Height__c, 24);
            String typeValue = normalizeType(field.Field_Type__c);

            if (typeValue == 'Checkbox') {
                if (isTruthy(value)) {
                    Decimal boxSize = minDecimal(height, 12);
                    Decimal centerY = y + ((height - boxSize) / 2);
                    lines.add(rectangleStroke(x, centerY, boxSize, boxSize));
                    lines.add(checkmarkStroke(x, centerY, boxSize));
                }
                continue;
            }

            Decimal fontSize = fontSizeFor(typeValue, width, height, value);
            Decimal textX = x + 1;
            Decimal textY = y + ((height - fontSize) / 2) + 1;
            if (textY < y + 1) {
                textY = y + 1;
            }
            String fontName = typeValue == 'Signature' ? 'F2' : 'F1';
            lines.add(textLine(fontName, fontSize, textX, textY, value));
        }
        return String.join(lines, '\n');
    }

    private static String buildPdfDocument(String content, Decimal pageWidth, Decimal pageHeight) {
        List<String> objects = new List<String>();
        objects.add('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
        objects.add('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
        objects.add('3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ' + fmt(pageWidth) + ' ' + fmt(pageHeight) + '] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>\nendobj\n');
        objects.add('4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n');
        objects.add('5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique >>\nendobj\n');
        objects.add('6 0 obj\n<< /Length ' + content.length() + ' >>\nstream\n' + content + '\nendstream\nendobj\n');

        String pdf = '%PDF-1.4\n';
        List<Integer> offsets = new List<Integer>();
        for (String obj : objects) {
            offsets.add(pdf.length());
            pdf += obj;
        }
        Integer xrefOffset = pdf.length();
        pdf += 'xref\n0 ' + String.valueOf(objects.size() + 1) + '\n';
        pdf += '0000000000 65535 f \n';
        for (Integer offset : offsets) {
            pdf += leftPad(String.valueOf(offset), 10, '0') + ' 00000 n \n';
        }
        pdf += 'trailer\n<< /Size ' + String.valueOf(objects.size() + 1) + ' /Root 1 0 R >>\nstartxref\n' + String.valueOf(xrefOffset) + '\n%%EOF\n';
        return pdf;
    }

    private static String textLine(String fontName, Decimal fontSize, Decimal x, Decimal y, String value) {
        return 'BT /' + fontName + ' ' + fmt(fontSize) + ' Tf ' + fmt(x) + ' ' + fmt(y) + ' Td (' + pdfEscape(value) + ') Tj ET';
    }

    private static String rectangleStroke(Decimal x, Decimal y, Decimal width, Decimal height) {
        return 'q 0.8 w ' + fmt(x) + ' ' + fmt(y) + ' ' + fmt(width) + ' ' + fmt(height) + ' re S Q';
    }

    private static String checkmarkStroke(Decimal x, Decimal y, Decimal sizeValue) {
        Decimal x1 = x + (sizeValue * 0.18);
        Decimal y1 = y + (sizeValue * 0.52);
        Decimal x2 = x + (sizeValue * 0.42);
        Decimal y2 = y + (sizeValue * 0.24);
        Decimal x3 = x + (sizeValue * 0.84);
        Decimal y3 = y + (sizeValue * 0.78);
        return 'q 1.2 w ' + fmt(x1) + ' ' + fmt(y1) + ' m ' + fmt(x2) + ' ' + fmt(y2) + ' l ' + fmt(x3) + ' ' + fmt(y3) + ' l S Q';
    }

    private static Decimal fontSizeFor(String typeValue, Decimal width, Decimal height, String value) {
        Decimal baseSize;
        if (typeValue == 'Signature') {
            baseSize = minDecimal(height * 0.72, 24);
        } else if (typeValue == 'Initials') {
            baseSize = minDecimal(height * 0.70, 16);
        } else {
            baseSize = minDecimal(height * 0.62, 11);
        }
        if (baseSize < 7) {
            baseSize = 7;
        }
        Integer len = String.isBlank(value) ? 1 : value.length();
        Decimal maxByWidth = width / (Math.max(len, 1) * 0.52);
        if (maxByWidth > 0 && maxByWidth < baseSize) {
            baseSize = maxByWidth;
        }
        if (baseSize < 6) {
            baseSize = 6;
        }
        return baseSize.setScale(2);
    }

    private static String normalizeText(String value) {
        if (value == null) {
            return null;
        }
        return value.replace('\r', ' ').replace('\n', ' ').replace('\t', ' ').trim();
    }

    private static String normalizeType(String value) {
        return String.isBlank(value) ? '' : value.trim();
    }

    private static String signedDateText(Datetime signedAt) {
        Date d = signedAt == null ? Date.today() : signedAt.dateGmt();
        return String.valueOf(d.month()) + '/' + String.valueOf(d.day()) + '/' + String.valueOf(d.year());
    }

    private static String pdfEscape(String value) {
        if (value == null) {
            return '';
        }
        String output = '';
        for (Integer i = 0; i < value.length(); i++) {
            String ch = value.substring(i, i + 1);
            if (ch == '\\') {
                output += '\\\\';
            } else if (ch == '(') {
                output += '\\(';
            } else if (ch == ')') {
                output += '\\)';
            } else {
                output += ch;
            }
        }
        return output;
    }

    private static Boolean isTruthy(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        String v = value.trim().toLowerCase();
        return v == 'true' || v == 'yes' || v == 'y' || v == '1' || v == 'checked' || v == 'x';
    }

    private static Decimal firstNonNull(Decimal value, Decimal fallback) {
        return value == null ? fallback : value;
    }

    private static Decimal minDecimal(Decimal a, Decimal b) {
        return a < b ? a : b;
    }

    private static Decimal maxDecimal(Decimal a, Decimal b) {
        return a > b ? a : b;
    }

    private static String fmt(Decimal value) {
        if (value == null) {
            value = 0;
        }
        Decimal scaled = value.setScale(2);
        String output = String.valueOf(scaled);
        while (output.contains('.') && output.endsWith('0')) {
            output = output.left(output.length() - 1);
        }
        if (output.endsWith('.')) {
            output = output.left(output.length() - 1);
        }
        return output;
    }

    private static String leftPad(String value, Integer length, String pad) {
        if (value == null) {
            value = '';
        }
        while (value.length() < length) {
            value = pad + value;
        }
        return value;
    }
}