@RestResource(urlMapping='/ESignature/v1/email-open')
global without sharing class ESignatureEmailOpenResource {
    private static final String PIXEL_BASE64 = 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';

    @HttpGet
    global static void getPixel() {
        RestResponse response = RestContext.response;
        if (response == null) {
            response = new RestResponse();
            RestContext.response = response;
        }

        response.statusCode = 200;
        response.addHeader('Content-Type', 'image/gif');
        response.addHeader('Cache-Control', 'no-store, no-cache, max-age=0');
        response.responseBody = EncodingUtil.base64Decode(PIXEL_BASE64);

        String token = RestContext.request == null ? null : RestContext.request.params.get('t');
        ESignature_Envelope__c env = ESignatureUtil.findEnvelopeByToken(token);
        if (env == null) {
            return;
        }

        Map<String, Object> payload = new Map<String, Object>{
            'message' => 'Signer opened the initial signature request email.'
        };
        addRestRequestContext(payload);
        ESignatureUtil.publishSignerCommand('Email Opened', env, token, payload, false);
    }

    private static void addRestRequestContext(Map<String, Object> payload) {
        if (payload == null) {
            return;
        }
        payload.put('serverTimestamp', System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        try {
            RestRequest request = RestContext.request;
            if (request == null || request.headers == null) {
                return;
            }
            payload.put('userAgent', request.headers.get('User-Agent'));
            String ipAddress = request.headers.get('True-Client-IP');
            if (String.isBlank(ipAddress)) {
                ipAddress = request.headers.get('X-Salesforce-SIP');
            }
            if (String.isBlank(ipAddress)) {
                ipAddress = request.headers.get('X-Forwarded-For');
            }
            payload.put('ipAddress', ipAddress);
        } catch (Exception ignore) {}
    }
}
