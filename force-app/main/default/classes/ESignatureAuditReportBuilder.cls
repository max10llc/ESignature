public without sharing class ESignatureAuditReportBuilder {
    private static final Decimal PAGE_WIDTH = 612;
    private static final Decimal PAGE_HEIGHT = 792;
    private static final Decimal REPORT_BORDER_X = 60;
    private static final Decimal REPORT_BORDER_WIDTH = 492;
    private static final Decimal REPORT_BORDER_BOTTOM = 40;
    private static final Decimal REPORT_BORDER_HEIGHT = 704;
    private static final Decimal TEXT_X = 82;
    private static final Decimal ICON_TEXT_X = 108;
    private static final Decimal CONTENT_RIGHT_X = REPORT_BORDER_X + REPORT_BORDER_WIDTH - 22;
    private static final Decimal CONTENT_TEXT_WIDTH = CONTENT_RIGHT_X - TEXT_X;
    private static final Decimal CONTENT_BOTTOM = 48;
    private static final String AUDIT_DATE_FORMAT = 'MM-dd-yyyy';
    private static final String AUDIT_DATE_TIME_FORMAT = 'MM-dd-yyyy - h:mm:ss a z';

    private class PdfSegment {
        public String text;
        public String fontName;
        public Integer fontSize;

        public PdfSegment(String text, String fontName, Integer fontSize) {
            this.text = text == null ? '' : text;
            this.fontName = String.isBlank(fontName) ? 'F2' : fontName;
            this.fontSize = fontSize == null ? 10 : fontSize;
        }
    }

    private class PdfImageResource {
        public String name;
        public String hexData;
        public Integer width = 64;
        public Integer height = 64;
        public Integer objectNumber;
        public String pdfName;

        public PdfImageResource(String name, Blob body) {
            this.name = name;
            this.hexData = EncodingUtil.convertToHex(body);
            List<Integer> dimensions = getJpegDimensions(this.hexData);
            this.width = dimensions[0];
            this.height = dimensions[1];
        }
    }

    private class PdfRow {
        public List<PdfSegment> segments = new List<PdfSegment>();
        public Integer lineHeight = 15;
        public Decimal indent = 0;
        public String iconResourceName;

        public PdfRow icon(String staticResourceName) {
            this.iconResourceName = staticResourceName;
            if (lineHeight < 18) {
                lineHeight = 18;
            }
            return this;
        }

        public PdfRow offset(Decimal value) {
            this.indent = value == null ? 0 : value;
            return this;
        }

        public PdfRow add(String text, String fontName, Integer fontSize) {
            segments.add(new PdfSegment(text, fontName, fontSize));
            Integer neededHeight = (fontSize == null ? 10 : fontSize) + 5;
            if (neededHeight > lineHeight) {
                lineHeight = neededHeight;
            }
            return this;
        }
    }

    public static Blob buildAuditReportPdf(Id envelopeId) {
        return buildAuditReportPdf(envelopeId, null);
    }

    public static Blob buildAuditReportPdf(Id envelopeId, String sourceTitle) {
        if (envelopeId == null) {
            throw new ESignatureUtil.AppException('Envelope Id is required to build the final audit report.');
        }
        ESignature_Envelope__c env = loadEnvelope(envelopeId);
        List<ESignature_Audit_Event__c> events = loadAuditEvents(envelopeId);
        return buildPdfRows(buildRows(env, events, sourceTitle));
    }

    public static String buildAuditReportBase64(Id envelopeId, String sourceTitle) {
        return EncodingUtil.base64Encode(buildAuditReportPdf(envelopeId, sourceTitle));
    }

    private static ESignature_Envelope__c loadEnvelope(Id envelopeId) {
        List<ESignature_Envelope__c> rows = [
            SELECT Id, Name, CreatedDate, Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c,
                   Signer_Name__c, Signer_Email__c, Signer_Title__c, Sender_User__c, Sender_User__r.Email,
                   Sender_User__r.TimeZoneSidKey, Sent_At__c, Viewed_At__c, Signed_At__c, Signature_Method__c
            FROM ESignature_Envelope__c
            WHERE Id = :envelopeId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new ESignatureUtil.AppException('Envelope not found for final audit report.');
        }
        return rows[0];
    }

    private static List<ESignature_Audit_Event__c> loadAuditEvents(Id envelopeId) {
        return [
            SELECT Event_Type__c, Occurred_At__c, Actor_Email__c, Details__c, IP_Address__c, User_Agent__c
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :envelopeId
            ORDER BY Occurred_At__c ASC, CreatedDate ASC
        ];
    }

    private static List<PdfRow> buildRows(
        ESignature_Envelope__c env,
        List<ESignature_Audit_Event__c> events,
        String sourceTitle
    ) {
        List<PdfRow> rows = new List<PdfRow>();
        String documentTitle = firstNonBlank(new List<String>{ sourceTitle, env.Source_File_Title__c, env.Name, 'Document' });
        String auditTimeZoneSid = auditTimeZoneSid(env);
        String createdDate = formatDate(env.CreatedDate, auditTimeZoneSid);
        String senderEmail = env.Sender_User__r == null ? UserInfo.getUserEmail() : env.Sender_User__r.Email;
        String signerName = nullToBlank(env.Signer_Name__c);
        String signerEmail = nullToBlank(env.Signer_Email__c);
        String transactionId = String.valueOf(env.Id);
        ESignature_Audit_Event__c sentEvent = firstEvent(events, new Set<String>{ 'Sent' });
        ESignature_Audit_Event__c viewedEvent = firstEvent(events, new Set<String>{ 'Viewed' });
        ESignature_Audit_Event__c disclosureEvent = firstEvent(events, new Set<String>{ 'Disclosure Accepted' });
        ESignature_Audit_Event__c signedEvent = firstEvent(events, new Set<String>{ 'Signed' });

        for (String titleLine : wrapLineByWidth(documentTitle, CONTENT_TEXT_WIDTH, 'F1', 18)) {
            rows.add(new PdfRow().add(titleLine, 'F1', 18));
        }
        rows.add(new PdfRow().add('Final Audit Report', 'F1', 15).add('   ' + createdDate, 'F2', 11));
        rows.add(new PdfRow().add('', 'F2', 8));

        rows.add(new PdfRow().add('SUMMARY', 'F1', 11));
        rows.add(new PdfRow().add('Created: ', 'F1', 10).add(createdDate, 'F2', 10));
        rows.add(new PdfRow().add('By: ', 'F1', 10).add(nullToBlank(senderEmail), 'F2', 10));
        rows.add(new PdfRow().add('Status: ', 'F1', 10).add('Completed', 'F1', 10));
        rows.add(new PdfRow().add('Transaction ID: ', 'F1', 9).add(transactionId, 'F2', 8));
        rows.add(new PdfRow().add('', 'F2', 7));

        for (String historyLine : wrapLineByWidth('"' + documentTitle + '" History', CONTENT_TEXT_WIDTH, 'F1', 12)) {
            rows.add(new PdfRow().add(historyLine, 'F1', 12));
        }
        rows.add(new PdfRow().add('', 'F2', 6));

        addEventRows(
            rows,
            'Document_Icon',
            'Document Created',
            'Created by ' + nullToBlank(senderEmail),
            formatDateTime(env.CreatedDate, auditTimeZoneSid),
            'Source: Salesforce E-Signature'
        );
        addEventRows(
            rows,
            'Document_Sent_Icon',
            'Document Emailed',
            'Sent to ' + signerName + ' (' + signerEmail + ') for signature',
            firstNonBlank(new List<String>{
                formatDateTime(sentEvent == null ? env.Sent_At__c : sentEvent.Occurred_At__c, auditTimeZoneSid),
                'E-Signature request sent from Salesforce'
            }),
            ''
        );
        addEventRows(
            rows,
            'Document_Sent_Icon',
            'Signer Accessed Secure Link',
            signerName + ' (' + signerEmail + ') accessed the secure signing link',
            firstNonBlank(new List<String>{
                formatDateTime(viewedEvent == null ? env.Viewed_At__c : viewedEvent.Occurred_At__c, auditTimeZoneSid),
                'Verification code not required by sender configuration'
            }),
            ''
        );
        if (disclosureEvent != null) {
            addEventRows(
                rows,
                'Document_Signed_Icon',
                'Consumer Disclosure Accepted',
                signerName + ' (' + signerEmail + ') accepted the Consumer Disclosure and consented to use electronic signatures',
                formatDateTime(disclosureEvent.Occurred_At__c, auditTimeZoneSid),
                ''
            );
        }
        if (env.Signed_At__c != null) {
            addEventRows(
                rows,
                'Document_Signed_Icon',
                'Document E-Signed',
                signerName + ' (' + signerEmail + ') electronically signed the document',
                'Signature Date: ' + formatDateTime(env.Signed_At__c, auditTimeZoneSid),
                'IP address: ' + nullToBlank(signedEvent == null ? null : signedEvent.IP_Address__c)
            );
            addEventRows(
                rows,
                'Document_Completed_Icon',
                'Agreement Completed',
                'All required signer actions are complete',
                formatDateTime(env.Signed_At__c, auditTimeZoneSid),
                'Signature Appearance Selected: ELECTRONIC'
            );
        }
        if (isFinalPdfSecured()) {
            rows.add(new PdfRow().icon('Document_Locked_Icon').add('Secured Document', 'F1', 10));
            for (String securedNotice : wrapLine('This completed agreement has been secured. Opening and viewing are allowed, but editing or changing the document is restricted.', 78)) {
                rows.add(new PdfRow().offset(18).add(securedNotice, 'F2', 9));
            }
        }
        return rows;
    }

    private static void addEventRows(List<PdfRow> rows, String iconResourceName, String title, String detail, String timestamp, String extraDetail) {
        rows.add(new PdfRow().icon(iconResourceName).add(title, 'F1', 10));
        addWrappedRows(rows, detail, 78, 'F2', 9, 2);
        if (String.isNotBlank(timestamp)) {
            addWrappedRows(rows, timestamp, 78, 'F2', 9, 1);
        }
        if (String.isNotBlank(extraDetail)) {
            addWrappedRows(rows, extraDetail, 78, 'F2', 9, 1);
        }
        rows.add(spacer(8));
    }

    private static PdfRow spacer(Integer lineHeight) {
        PdfRow row = new PdfRow().add('', 'F2', 1);
        row.lineHeight = lineHeight == null ? 8 : lineHeight;
        return row;
    }

    private static void addWrappedRows(List<PdfRow> rows, String text, Integer maxLength, String fontName, Integer fontSize, Integer maxLines) {
        Integer added = 0;
        for (String wrapped : wrapLine(text, maxLength)) {
            if (maxLines != null && added >= maxLines) {
                rows.add(new PdfRow().offset(18).add('...', fontName, fontSize));
                return;
            }
            rows.add(new PdfRow().offset(18).add(wrapped, fontName, fontSize));
            added++;
        }
    }

    private static Blob buildPdfRows(List<PdfRow> rows) {
        Map<String, PdfImageResource> images = loadPdfImageResources(rows);
        Integer nextObjectNumber = 7;
        Integer imageIndex = 1;
        for (PdfImageResource image : images.values()) {
            image.objectNumber = nextObjectNumber++;
            image.pdfName = 'Im' + imageIndex++;
        }
        Integer contentObjectNumber = nextObjectNumber;

        List<String> contentLines = new List<String>();
        contentLines.add('q');
        contentLines.add('0.75 w');
        contentLines.add(formatPdfNumber(REPORT_BORDER_X) + ' ' + formatPdfNumber(REPORT_BORDER_BOTTOM) + ' '
            + formatPdfNumber(REPORT_BORDER_WIDTH) + ' ' + formatPdfNumber(REPORT_BORDER_HEIGHT) + ' re');
        contentLines.add('S');
        contentLines.add('Q');

        Decimal y = 722;
        for (PdfRow row : rows) {
            if (y < CONTENT_BOTTOM) {
                break;
            }
            Decimal textX = String.isBlank(row.iconResourceName) ? TEXT_X + row.indent : ICON_TEXT_X + row.indent;
            if (String.isNotBlank(row.iconResourceName) && images.containsKey(row.iconResourceName)) {
                PdfImageResource image = images.get(row.iconResourceName);
                Decimal iconSize = 15;
                Decimal iconX = TEXT_X;
                Decimal iconY = y - 5;
                contentLines.add('q');
                contentLines.add(formatPdfNumber(iconSize) + ' 0 0 ' + formatPdfNumber(iconSize) + ' ' + formatPdfNumber(iconX) + ' ' + formatPdfNumber(iconY) + ' cm');
                contentLines.add('/' + image.pdfName + ' Do');
                contentLines.add('Q');
            }
            if (row.segments.isEmpty()) {
                row.add('', 'F2', 10);
            }

            Decimal cursorX = textX;
            for (PdfSegment segment : row.segments) {
                contentLines.add('BT');
                contentLines.add('/' + segment.fontName + ' ' + segment.fontSize + ' Tf');
                contentLines.add('1 0 0 1 ' + formatPdfNumber(cursorX) + ' ' + formatPdfNumber(y) + ' Tm');
                contentLines.add('(' + escapePdfText(segment.text) + ') Tj');
                contentLines.add('ET');
                cursorX += approximateTextWidth(segment.text, segment.fontName, segment.fontSize);
            }
            y -= row.lineHeight;
        }

        String stream = String.join(contentLines, '\n') + '\n';
        List<String> objects = new List<String>();
        String xObjectResource = buildXObjectResourceDictionary(images);

        objects.add('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
        objects.add('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
        objects.add('3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ' + formatPdfNumber(PAGE_WIDTH) + ' ' + formatPdfNumber(PAGE_HEIGHT) + '] /Resources << /Font << /F1 4 0 R /F2 5 0 R /F3 6 0 R >> ' + xObjectResource + ' >> /Contents ' + contentObjectNumber + ' 0 R >>\nendobj\n');
        objects.add('4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>\nendobj\n');
        objects.add('5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n');
        objects.add('6 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique >>\nendobj\n');

        for (PdfImageResource image : images.values()) {
            String imageStream = image.hexData + '>';
            objects.add(
                image.objectNumber + ' 0 obj\n'
                + '<< /Type /XObject /Subtype /Image /Width ' + image.width + ' /Height ' + image.height
                + ' /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter [/ASCIIHexDecode /DCTDecode] /Length ' + imageStream.length() + ' >>\n'
                + 'stream\n' + imageStream + '\nendstream\nendobj\n'
            );
        }
        objects.add(contentObjectNumber + ' 0 obj\n<< /Length ' + stream.length() + ' >>\nstream\n' + stream + 'endstream\nendobj\n');

        String header = '%PDF-1.4\n';
        List<Integer> offsets = new List<Integer>();
        Integer offset = header.length();
        for (String obj : objects) {
            offsets.add(offset);
            offset += obj.length();
        }

        String xref = 'xref\n0 ' + (objects.size() + 1) + '\n0000000000 65535 f \n';
        for (Integer objOffset : offsets) {
            xref += leftPadNumber(objOffset, 10) + ' 00000 n \n';
        }

        String trailer = 'trailer\n<< /Size ' + (objects.size() + 1) + ' /Root 1 0 R >>\nstartxref\n' + offset + '\n%%EOF';
        return Blob.valueOf(header + String.join(objects, '') + xref + trailer);
    }

    private static Map<String, PdfImageResource> loadPdfImageResources(List<PdfRow> rows) {
        Set<String> names = new Set<String>();
        for (PdfRow row : rows) {
            if (String.isNotBlank(row.iconResourceName)) {
                names.add(row.iconResourceName);
            }
        }

        Map<String, PdfImageResource> images = new Map<String, PdfImageResource>();
        if (names.isEmpty()) {
            return images;
        }

        for (StaticResource sr : [
            SELECT Name, Body, ContentType
            FROM StaticResource
            WHERE Name IN :names
        ]) {
            if (sr.Body != null) {
                images.put(sr.Name, new PdfImageResource(sr.Name, sr.Body));
            }
        }
        return images;
    }

    private static String buildXObjectResourceDictionary(Map<String, PdfImageResource> images) {
        if (images == null || images.isEmpty()) {
            return '';
        }
        String value = '/XObject << ';
        for (PdfImageResource image : images.values()) {
            value += '/' + image.pdfName + ' ' + image.objectNumber + ' 0 R ';
        }
        return value + '>>';
    }

    private static ESignature_Audit_Event__c firstEvent(List<ESignature_Audit_Event__c> events, Set<String> eventTypes) {
        if (events == null || eventTypes == null || eventTypes.isEmpty()) {
            return null;
        }
        for (ESignature_Audit_Event__c evt : events) {
            if (evt != null && eventTypes.contains(evt.Event_Type__c)) {
                return evt;
            }
        }
        return null;
    }

    private static Boolean isFinalPdfSecured() {
        try {
            ESignature_Setting__mdt settings = ESignatureUtil.getSettings();
            return settings != null
                && (settings.Restrict_Editing__c == true
                    || settings.Restrict_Copying__c == true
                    || String.isNotBlank(settings.Final_Pdf_Owner_Password__c));
        } catch (Exception ex) {
            return false;
        }
    }

    private static Decimal approximateTextWidth(String text, String fontName, Integer fontSize) {
        Integer sizeValue = fontSize == null ? 10 : fontSize;
        Decimal widthUnits = 0;
        String value = nullToBlank(text);
        for (Integer i = 0; i < value.length(); i++) {
            widthUnits += helveticaWidthUnits(value.substring(i, i + 1), fontName);
        }
        return widthUnits * Decimal.valueOf(sizeValue) / Decimal.valueOf(1000);
    }

    private static Decimal helveticaWidthUnits(String ch, String fontName) {
        if (String.isBlank(ch)) {
            return 278;
        }
        if (ch == 'I' || ch == 'i' || ch == 'j' || ch == 'l') return 278;
        if (ch == 'W') return 944;
        if (ch == 'M' || ch == 'm') return 833;
        if (ch == 'G' || ch == 'O' || ch == 'Q' || ch == 'w') return 778;
        if ('ABCDEHKNRU'.contains(ch)) return 722;
        if ('SXY'.contains(ch)) return 667;
        if ('FLTZ'.contains(ch)) return 611;
        if ('0123456789'.contains(ch)) return 556;
        if ('bdghnopqu'.contains(ch)) return 611;
        if ('aceksvxzy'.contains(ch)) return 556;
        if (ch == 'f' || ch == 'r') return 389;
        if (ch == 't') return 333;
        if (ch == '"' || ch == '@') return 474;
        if (ch == '-' || ch == '(' || ch == ')' || ch == ':' || ch == ';') return 333;
        if (ch == '.' || ch == ',' || ch == '\'' || ch == '/') return 278;
        return 556;
    }

    private static String formatPdfNumber(Decimal value) {
        if (value == null) {
            return '0';
        }
        return String.valueOf(value.setScale(2)).replaceAll('0+$', '').replaceAll('\\.$', '');
    }

    private static List<Integer> getJpegDimensions(String hexData) {
        try {
            if (String.isBlank(hexData) || hexData.length() < 40 || !hexData.startsWith('ffd8')) {
                return new List<Integer>{ 64, 64 };
            }

            Integer pos = 4;
            while (pos + 18 < hexData.length()) {
                while (pos + 2 < hexData.length() && hexData.substring(pos, pos + 2) != 'ff') {
                    pos += 2;
                }
                while (pos + 4 < hexData.length() && hexData.substring(pos, pos + 2) == 'ff') {
                    pos += 2;
                }
                if (pos + 8 >= hexData.length()) {
                    break;
                }

                String marker = hexData.substring(pos, pos + 2).toLowerCase();
                pos += 2;
                if (marker == 'd9' || marker == 'da') {
                    break;
                }

                Integer segmentLength = hexToInt(hexData.substring(pos, pos + 4));
                if (isJpegStartOfFrameMarker(marker) && pos + 14 < hexData.length()) {
                    Integer height = hexToInt(hexData.substring(pos + 6, pos + 10));
                    Integer width = hexToInt(hexData.substring(pos + 10, pos + 14));
                    if (width > 0 && height > 0) {
                        return new List<Integer>{ width, height };
                    }
                }

                if (segmentLength <= 0) {
                    break;
                }
                pos += segmentLength * 2;
            }
        } catch (Exception ex) {
            // Use default dimensions when resource metadata cannot be read.
        }
        return new List<Integer>{ 64, 64 };
    }

    private static Boolean isJpegStartOfFrameMarker(String marker) {
        return new Set<String>{ 'c0', 'c1', 'c2', 'c3', 'c5', 'c6', 'c7', 'c9', 'ca', 'cb', 'cd', 'ce', 'cf' }.contains(marker);
    }

    private static Integer hexToInt(String hex) {
        Integer value = 0;
        for (Integer i = 0; i < hex.length(); i++) {
            value = value * 16 + hexCharToInt(hex.substring(i, i + 1));
        }
        return value;
    }

    private static Integer hexCharToInt(String ch) {
        String c = ch.toLowerCase();
        if (c == '0') return 0;
        if (c == '1') return 1;
        if (c == '2') return 2;
        if (c == '3') return 3;
        if (c == '4') return 4;
        if (c == '5') return 5;
        if (c == '6') return 6;
        if (c == '7') return 7;
        if (c == '8') return 8;
        if (c == '9') return 9;
        if (c == 'a') return 10;
        if (c == 'b') return 11;
        if (c == 'c') return 12;
        if (c == 'd') return 13;
        if (c == 'e') return 14;
        if (c == 'f') return 15;
        return 0;
    }

    private static List<String> wrapLine(String input, Integer maxLength) {
        List<String> lines = new List<String>();
        String value = sanitizePdfText(nullToBlank(input)).trim();
        if (String.isBlank(value)) {
            lines.add('');
            return lines;
        }
        if (value.length() <= maxLength) {
            lines.add(value);
            return lines;
        }

        while (value.length() > maxLength) {
            Integer breakAt = maxLength;
            for (Integer i = maxLength; i > 20; i--) {
                if (value.substring(i, i + 1) == ' ') {
                    breakAt = i;
                    break;
                }
            }
            lines.add(value.substring(0, breakAt).trim());
            value = value.substring(breakAt).trim();
        }
        if (value.length() > 0) {
            lines.add(value);
        }
        return lines;
    }

    private static List<String> wrapLineByWidth(String input, Decimal maxWidth, String fontName, Integer fontSize) {
        List<String> lines = new List<String>();
        String value = sanitizePdfText(nullToBlank(input)).trim();
        if (String.isBlank(value)) {
            lines.add('');
            return lines;
        }
        if (maxWidth == null || maxWidth <= 0 || approximateTextWidth(value, fontName, fontSize) <= maxWidth) {
            lines.add(value);
            return lines;
        }

        while (!String.isBlank(value)) {
            Integer breakAt = breakPositionForWidth(value, maxWidth, fontName, fontSize);
            lines.add(value.substring(0, breakAt).trim());
            value = value.substring(breakAt).trim();
        }
        return lines;
    }

    private static Integer breakPositionForWidth(String value, Decimal maxWidth, String fontName, Integer fontSize) {
        Integer lastSpaceAt = -1;
        for (Integer i = 1; i <= value.length(); i++) {
            String currentChar = value.substring(i - 1, i);
            if (currentChar == ' ') {
                lastSpaceAt = i - 1;
            }
            String candidate = value.substring(0, i);
            if (approximateTextWidth(candidate, fontName, fontSize) > maxWidth) {
                if (lastSpaceAt > 0) {
                    return lastSpaceAt;
                }
                return Math.max(1, i - 1);
            }
        }
        return value.length();
    }

    private static String sanitizePdfText(String input) {
        if (input == null) {
            return '';
        }
        return input.replace('\r', ' ').replace('\n', ' ').replace('\t', ' ').replaceAll('[^\\x20-\\x7E]', '?');
    }

    private static String escapePdfText(String input) {
        return sanitizePdfText(input).replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)');
    }

    private static String nullToBlank(Object input) {
        return input == null ? '' : String.valueOf(input);
    }

    private static String firstNonBlank(List<String> values) {
        if (values != null) {
            for (String value : values) {
                if (String.isNotBlank(value)) {
                    return value;
                }
            }
        }
        return '';
    }

    private static String auditTimeZoneSid(ESignature_Envelope__c env) {
        String senderTimeZone = env == null || env.Sender_User__r == null ? null : env.Sender_User__r.TimeZoneSidKey;
        if (String.isNotBlank(senderTimeZone)) {
            return senderTimeZone;
        }
        TimeZone runningUserTimeZone = UserInfo.getTimeZone();
        return runningUserTimeZone == null ? 'GMT' : runningUserTimeZone.getID();
    }

    private static String formatDate(Datetime value, String timeZoneSid) {
        return value == null ? '' : value.format(AUDIT_DATE_FORMAT, timeZoneSid);
    }

    private static String formatDateTime(Datetime value, String timeZoneSid) {
        return value == null ? '' : value.format(AUDIT_DATE_TIME_FORMAT, timeZoneSid);
    }

    private static String leftPadNumber(Integer value, Integer size) {
        String output = String.valueOf(value);
        while (output.length() < size) {
            output = '0' + output;
        }
        return output;
    }
}
