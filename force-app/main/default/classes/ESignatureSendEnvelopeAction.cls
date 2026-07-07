public with sharing class ESignatureSendEnvelopeAction {
    public class Request {
        @InvocableVariable(label='Envelope Id' description='Optional E-Signature Envelope Id to send. If omitted, provide Envelope Record, Envelope Records, or Parent Record Id.')
        public String envelopeId;

        @InvocableVariable(label='Envelope Record' description='Optional E-Signature Envelope record, such as a single record returned by Flow Get Records.')
        public ESignature_Envelope__c envelopeRecord;

        @InvocableVariable(label='Envelope Records' description='Optional E-Signature Envelope record collection. The first valid draft envelope in the collection is sent.')
        public List<ESignature_Envelope__c> envelopeRecords;

        @InvocableVariable(label='Parent Record Id' description='Optional parent Account, Case, Opportunity, or Work Order record Id. Used to find the latest draft envelope when no envelope is provided.')
        public String parentRecordId;

        @InvocableVariable(label='Signer Contact Id' description='Optional Contact Id. Name, email, and title are used when the matching signer fields below are blank.')
        public String signerContactId;

        @InvocableVariable(label='Signer Name' description='Signer name. Required unless Signer Contact Id provides a name.')
        public String signerName;

        @InvocableVariable(label='Signer Email' description='Signer email. Required unless Signer Contact Id provides an email.')
        public String signerEmail;

        @InvocableVariable(label='Signer Title' description='Optional signer title. If blank, Signer Contact Id title is used when available.')
        public String signerTitle;

        @InvocableVariable(label='Subject' description='Required subject for the signer email.')
        public String requestSubject;

        @InvocableVariable(label='Message' description='Optional custom message to include in the signer email.')
        public String requestMessage;

        @InvocableVariable(label='Expiration Days' description='Optional expiration days. Defaults to package settings when blank.')
        public Integer expirationDays;
    }

    public class Response {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Envelope Id')
        public String envelopeId;

        @InvocableVariable(label='Status')
        public String status;

        @InvocableVariable(label='Signing URL')
        public String signingUrl;

        @InvocableVariable(label='Signer Email')
        public String signerEmail;

        @InvocableVariable(label='Message')
        public String message;
    }

    private class SignerInfo {
        String name;
        String email;
        String title;
    }

    @InvocableMethod(label='Send E-Signature Envelope' description='Sends a draft E-Signature Envelope using the same logic as the E-Signature Send Envelope component.')
    public static List<Response> sendEnvelopes(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            responses.add(sendRequest(request));
        }
        return responses;
    }

    private static Response sendRequest(Request request) {
        Response response = new Response();
        response.success = false;
        try {
            String envelopeId = resolveEnvelopeId(request);
            if (String.isBlank(envelopeId)) {
                response.message = 'No draft E-Signature Envelope was found to send.';
                return response;
            }

            SignerInfo signer = resolveSigner(request);
            String validationMessage = validateInputs(signer, request == null ? null : request.requestSubject);
            if (!String.isBlank(validationMessage)) {
                response.message = validationMessage;
                return response;
            }
            ESignatureSendController.SendResultDTO result = ESignatureSendController.sendEnvelope(
                envelopeId,
                signer.name,
                signer.email,
                signer.title,
                request == null ? null : request.expirationDays,
                request == null ? null : request.requestMessage,
                request == null ? null : request.requestSubject
            );

            response.success = true;
            response.envelopeId = result == null ? envelopeId : result.envelopeId;
            response.status = result == null ? null : result.status;
            response.signingUrl = result == null ? null : result.signingUrl;
            response.signerEmail = signer.email;
            response.message = result == null ? 'Envelope sent.' : result.message;
        } catch (Exception ex) {
            response.success = false;
            response.message = cleanErrorMessage(ex);
        }
        return response;
    }

    private static String validateInputs(SignerInfo signer, String requestSubject) {
        if (signer == null || String.isBlank(signer.name)) {
            return 'Signer name is required.';
        }
        if (String.isBlank(signer.email)) {
            return 'Signer email is required.';
        }
        if (String.isBlank(requestSubject)) {
            return 'Subject is required.';
        }
        return null;
    }

    private static String resolveEnvelopeId(Request request) {
        if (request == null) {
            return null;
        }
        Id parsedId = validEnvelopeId(request.envelopeId);
        if (parsedId != null) {
            return String.valueOf(parsedId);
        }
        if (request.envelopeRecord != null && request.envelopeRecord.Id != null) {
            return String.valueOf(request.envelopeRecord.Id);
        }
        if (request.envelopeRecords != null) {
            for (ESignature_Envelope__c envelope : request.envelopeRecords) {
                if (envelope != null && envelope.Id != null) {
                    return String.valueOf(envelope.Id);
                }
            }
        }
        List<ESignatureSendController.EnvelopeDTO> drafts =
            ESignatureSendController.getDraftEnvelopes(request.parentRecordId, String.valueOf(System.now().getTime()));
        return drafts.isEmpty() ? null : drafts[0].id;
    }

    private static Id validEnvelopeId(String value) {
        Id parsedId = ESignatureUtil.safeId(value);
        return parsedId != null && parsedId.getSObjectType() == ESignature_Envelope__c.SObjectType ? parsedId : null;
    }

    private static SignerInfo resolveSigner(Request request) {
        Contact contact = loadSignerContact(request == null ? null : request.signerContactId);
        SignerInfo signer = new SignerInfo();
        signer.name = ESignatureUtil.firstNonBlank(new List<String>{
            request == null ? null : request.signerName,
            contact == null ? null : contact.Name
        });
        signer.email = ESignatureUtil.firstNonBlank(new List<String>{
            request == null ? null : request.signerEmail,
            contact == null ? null : contact.Email
        });
        signer.title = ESignatureUtil.firstNonBlank(new List<String>{
            request == null ? null : request.signerTitle,
            contact == null ? null : contact.Title
        });
        return signer;
    }

    private static Contact loadSignerContact(String contactIdValue) {
        Id contactId = ESignatureUtil.safeId(contactIdValue);
        if (contactId == null || contactId.getSObjectType() != Contact.SObjectType) {
            return null;
        }
        List<Contact> contacts = [
            SELECT Id, Name, Email, Title
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        return contacts.isEmpty() ? null : contacts[0];
    }

    private static String cleanErrorMessage(Exception ex) {
        if (ex == null || String.isBlank(ex.getMessage())) {
            return 'Unable to send E-Signature Envelope.';
        }
        String message = ex.getMessage();
        String scriptPrefix = 'Script-thrown exception';
        return message == scriptPrefix ? 'Unable to send E-Signature Envelope.' : message;
    }
}
