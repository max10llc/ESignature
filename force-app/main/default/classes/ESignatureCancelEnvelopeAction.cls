public with sharing class ESignatureCancelEnvelopeAction {
    public class Request {
        @InvocableVariable(label='Envelope Id' description='Single E-Signature Envelope record Id to cancel.')
        public String envelopeId;

        @InvocableVariable(label='Envelope Records' description='Optional E-Signature Envelope record collection, such as records returned by a Flow Get Records element.')
        public List<ESignature_Envelope__c> envelopeRecords;

        @InvocableVariable(label='Parent Record Id' description='Optional Account, Case, Opportunity, or Work Order record Id. All open related E-Signature Envelopes will be canceled.')
        public String parentRecordId;

        @InvocableVariable(label='Cancellation Reason' description='Optional reason to store on the cancellation audit event and email notification.')
        public String cancellationReason;

        @InvocableVariable(label='Send Cancellation Emails' description='Defaults to true. Sends cancellation emails to the signer and Salesforce user.')
        public Boolean sendCancellationEmails;
    }

    public class Response {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Requested Count')
        public Integer requestedCount;

        @InvocableVariable(label='Canceled Count')
        public Integer canceledCount;

        @InvocableVariable(label='Skipped Count')
        public Integer skippedCount;

        @InvocableVariable(label='Failed Count')
        public Integer failedCount;

        @InvocableVariable(label='Canceled Envelope Ids')
        public String canceledEnvelopeIds;

        @InvocableVariable(label='Failed Envelope Ids')
        public String failedEnvelopeIds;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(label='Cancel E-Signature Envelopes' description='Cancels one or many E-Signature Envelope records and writes cancellation audit events.')
    public static List<Response> cancelEnvelopes(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        for (Request request : requests) {
            responses.add(cancelRequest(request));
        }
        return responses;
    }

    private static Response cancelRequest(Request request) {
        Response response = new Response();
        response.requestedCount = 0;
        response.canceledCount = 0;
        response.skippedCount = 0;
        response.failedCount = 0;
        response.success = false;

        Set<Id> envelopeIds = parseEnvelopeIds(request);
        response.requestedCount = envelopeIds.size();
        if (envelopeIds.isEmpty()) {
            response.failedCount = 1;
            response.message = 'No valid E-Signature Envelope Ids were provided.';
            return response;
        }

        List<ESignatureEnvelopeCancellationService.CancellationResult> results =
            ESignatureEnvelopeCancellationService.cancelEnvelopes(
                envelopeIds,
                request == null ? null : request.cancellationReason,
                request == null ? null : request.sendCancellationEmails
            );

        List<String> canceledIds = new List<String>();
        List<String> failedIds = new List<String>();
        List<String> messages = new List<String>();
        for (ESignatureEnvelopeCancellationService.CancellationResult result : results) {
            if (result == null) {
                continue;
            }
            String envelopeId = result.envelopeId == null ? '' : String.valueOf(result.envelopeId);
            if (result.success == true && result.canceled == true) {
                response.canceledCount++;
                canceledIds.add(envelopeId);
            } else if (result.success == true) {
                response.skippedCount++;
            } else {
                response.failedCount++;
                failedIds.add(envelopeId);
            }
            if (!String.isBlank(result.message)) {
                messages.add(envelopeId + ': ' + result.message);
            }
        }

        response.success = response.failedCount == 0;
        response.canceledEnvelopeIds = String.join(canceledIds, ',');
        response.failedEnvelopeIds = String.join(failedIds, ',');
        response.message = summaryMessage(response, messages);
        return response;
    }

    private static Set<Id> parseEnvelopeIds(Request request) {
        Set<Id> output = new Set<Id>();
        if (request == null) {
            return output;
        }
        addEnvelopeId(output, request.envelopeId);
        if (request.envelopeRecords != null) {
            for (ESignature_Envelope__c envelope : request.envelopeRecords) {
                if (envelope != null) {
                    addEnvelopeId(output, String.valueOf(envelope.Id));
                }
            }
        }
        addOpenEnvelopeIdsForParent(output, request.parentRecordId);
        return output;
    }

    private static void addOpenEnvelopeIdsForParent(Set<Id> output, String parentRecordId) {
        if (output == null || String.isBlank(parentRecordId)) {
            return;
        }
        Set<String> parentRecordIds = ESignatureUtil.parentRecordIdValues(parentRecordId);
        Id parentId = ESignatureUtil.safeId(parentRecordId);
        if (parentRecordIds.isEmpty()) {
            return;
        }
        List<ESignature_Envelope__c> envelopes = parentId == null
            ? [
                SELECT Id
                FROM ESignature_Envelope__c
                WHERE Parent_Record_Id__c IN :parentRecordIds
                AND (Status__c = null OR Status__c IN ('Draft', 'Sent', 'Viewed', 'Error'))
            ]
            : [
                SELECT Id
                FROM ESignature_Envelope__c
                WHERE (Parent_Record_Id__c IN :parentRecordIds
                    OR Account__c = :parentId
                    OR Case__c = :parentId
                    OR Opportunity__c = :parentId
                    OR Work_Order__c = :parentId)
                AND (Status__c = null OR Status__c IN ('Draft', 'Sent', 'Viewed', 'Error'))
            ];
        for (ESignature_Envelope__c envelope : envelopes) {
            output.add(envelope.Id);
        }
    }

    private static void addEnvelopeId(Set<Id> output, String value) {
        if (output == null || String.isBlank(value)) {
            return;
        }
        Id parsedId = ESignatureUtil.safeId(value.trim());
        if (parsedId != null && parsedId.getSObjectType() == ESignature_Envelope__c.SObjectType) {
            output.add(parsedId);
        }
    }

    private static String summaryMessage(Response response, List<String> detailMessages) {
        String summary = 'Requested ' + response.requestedCount
            + ', canceled ' + response.canceledCount
            + ', skipped ' + response.skippedCount
            + ', failed ' + response.failedCount + '.';
        if (detailMessages == null || detailMessages.isEmpty()) {
            return summary;
        }
        return summary + ' ' + String.join(detailMessages, ' ');
    }
}
