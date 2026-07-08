import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import { loadScript } from 'lightning/platformResourceLoader';
import PDF_JS from '@salesforce/resourceUrl/ESignature_PdfJs';

import getPdfDocumentInfo from '@salesforce/apex/ESignaturePrepareController.getPdfDocumentInfo';
import getPlacements from '@salesforce/apex/ESignaturePrepareController.getPlacements';
import savePlacements from '@salesforce/apex/ESignaturePrepareController.savePlacements';

const DEFAULT_TEXT_FIELD_WIDTH = 0.26;
const DEFAULT_TEXT_FIELD_HEIGHT = 0.035;

const FIELD_TYPES = [
    { label: 'Signature', value: 'Signature', width: DEFAULT_TEXT_FIELD_WIDTH, height: DEFAULT_TEXT_FIELD_HEIGHT, defaultRequired: true },
    { label: 'Name', value: 'Name', width: DEFAULT_TEXT_FIELD_WIDTH, height: DEFAULT_TEXT_FIELD_HEIGHT, defaultRequired: true },
    { label: 'Title', value: 'Title', width: DEFAULT_TEXT_FIELD_WIDTH, height: DEFAULT_TEXT_FIELD_HEIGHT, defaultRequired: true },
    { label: 'Date', value: 'Date', width: DEFAULT_TEXT_FIELD_WIDTH, height: DEFAULT_TEXT_FIELD_HEIGHT, defaultRequired: true },
    { label: 'Initials', value: 'Initials', width: 0.072, height: 0.027, defaultRequired: true },
    { label: 'Checkbox', value: 'Checkbox', width: 0.045, height: 0.04, defaultRequired: false },
    { label: 'Text', value: 'Text', width: DEFAULT_TEXT_FIELD_WIDTH, height: DEFAULT_TEXT_FIELD_HEIGHT, defaultRequired: true }
];

const PALETTE_FIELD_TYPES = FIELD_TYPES;
const MIN_FIELD_WIDTH = 0.025;
const MIN_FIELD_HEIGHT = 0.025;
const DRAG_THRESHOLD_PIXELS = 6;
const AUTO_FIT_FIELD_TYPES = new Set(['Signature', 'Initials', 'Date', 'Name', 'Title', 'Text']);
const LINE_SCAN_Y_PERCENT = 0.025;
const LINE_MIN_WIDTH_PERCENT = 0.05;
const LINE_MAX_GAP_PERCENT = 0.01;
const LINE_START_GAP_PERCENT = 0.018;
const LINE_LUMA_THRESHOLD = 220;
const DEFAULT_VIEWER_HEIGHT = 525;
const MIN_VIEWER_HEIGHT = 448;
const VIEWPORT_BOTTOM_PADDING = 96;
const REQUIRED_FLOW_FIELD_TYPES = ['Signature', 'Name', 'Title', 'Date'];

export default class PdfESignPrepareDocument extends LightningElement {
    @api recordId;
    @api parentRecordId;
    @api contentDocumentId;
    @api height = DEFAULT_VIEWER_HEIGHT;
    @api isEnvelopeReady = false;
    @api preparedEnvelopeId;
    @api prepareValidationMessage = 'Add Signature, Name, Title, and Date fields, then click Save.';
    @api missingRequiredFields = REQUIRED_FLOW_FIELD_TYPES.join(', ');

    @track pages = [];
    @track fields = [];

    selectedContentDocumentId;
    selectedContentVersionId;
    fieldTypes = PALETTE_FIELD_TYPES;
    pdfInfo;
    loadError;
    selectedFieldId;
    pendingFieldType;
    draggedFieldType;
    isLoading = true;
    isSaving = false;
    loadingMessage = 'Starting document preparation...';
    zoom = 1.25;
    pageDimensions = new Map();
    pointerState;
    nextClientId = 1;
    hasInitialized = false;
    pdfJsLoadPromise;
    pageImageDataCache = new Map();
    saveNotice;
    saveNoticeTimeoutId;
    responsiveViewerHeight = DEFAULT_VIEWER_HEIGHT;
    viewportResizeFrameId;
    lastSavedPlacementSignature;

    connectedCallback() {
        this.boundHandlePointerMove = this.handlePointerMove.bind(this);
        this.boundHandlePointerUp = this.handlePointerUp.bind(this);
        this.boundHandlePointerCancel = this.handlePointerUp.bind(this);
        this.boundHandleViewportResize = this.handleViewportResize.bind(this);
        window.addEventListener('resize', this.boundHandleViewportResize);
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', this.boundHandleViewportResize);
        }
    }

    renderedCallback() {
        this.updateResponsiveHeight();
        if (this.hasInitialized) {
            return;
        }
        this.hasInitialized = true;
        this.initialize();
    }

    disconnectedCallback() {
        this.removePointerListeners();
        window.removeEventListener('resize', this.boundHandleViewportResize);
        if (window.visualViewport) {
            window.visualViewport.removeEventListener('resize', this.boundHandleViewportResize);
        }
        if (this.viewportResizeFrameId) {
            window.cancelAnimationFrame(this.viewportResizeFrameId);
            this.viewportResizeFrameId = null;
        }
        this.clearSaveNotice(false);
    }

    get effectiveParentRecordId() {
        return this.parentRecordId || this.recordId;
    }

    get activeContentDocumentId() {
        return this.contentDocumentId || this.selectedContentDocumentId;
    }

    get configuredViewerHeight() {
        const parsedHeight = Number(this.height);
        return Number.isFinite(parsedHeight) && parsedHeight > 0 ? parsedHeight : DEFAULT_VIEWER_HEIGHT;
    }

    get workspaceStyle() {
        const viewerHeight = this.responsiveViewerHeight || this.configuredViewerHeight;
        return `height: ${viewerHeight}px; max-height: ${viewerHeight}px;`;
    }

    get zoomPercent() {
        return Math.round(this.zoom * 100);
    }

    get noSelectedField() {
        return !this.selectedFieldId;
    }

    get selectedField() {
        return this.fields.find((field) => field.clientId === this.selectedFieldId);
    }

    get showClickToPlaceMessage() {
        return !!this.pendingFieldType;
    }

    get pendingFieldTypeLabel() {
        const fieldType = FIELD_TYPES.find((item) => item.value === this.pendingFieldType);
        return fieldType ? fieldType.label : '';
    }

    get hasSelectedPdf() {
        return !!this.pdfInfo;
    }

    get hasSaveNotice() {
        return !!this.saveNotice;
    }

    get saveNoticeClass() {
        const variant = this.saveNotice?.variant || 'info';
        const allowedVariants = ['error', 'info', 'success', 'warning'];
        const normalizedVariant = allowedVariants.includes(variant) ? variant : 'info';
        return `save-notice save-notice_${normalizedVariant} slds-m-bottom_small`;
    }

    get saveNoticeRole() {
        return this.saveNotice?.variant === 'error' ? 'alert' : 'status';
    }

    @api
    validate() {
        const state = this.syncFlowValidationOutputs();
        if (!state.isValid) {
            this.showSaveMessage('Envelope is not ready', state.message, 'error', 'sticky');
        }
        return {
            isValid: state.isValid,
            errorMessage: state.isValid ? null : state.message
        };
    }

    syncFlowValidationOutputs() {
        const state = this.getFlowValidationState();
        this.isEnvelopeReady = state.isValid;
        this.prepareValidationMessage = state.message;
        this.missingRequiredFields = state.missingFields.join(', ');
        this.dispatchFlowAttributeChange('isEnvelopeReady', this.isEnvelopeReady);
        this.dispatchFlowAttributeChange('preparedEnvelopeId', this.preparedEnvelopeId || null);
        this.dispatchFlowAttributeChange('prepareValidationMessage', this.prepareValidationMessage);
        this.dispatchFlowAttributeChange('missingRequiredFields', this.missingRequiredFields);
        return state;
    }

    getFlowValidationState() {
        const missingFields = this.getMissingRequiredFieldTypes();
        if (this.isLoading) {
            return { isValid: false, missingFields, message: 'Wait for the PDF to finish loading before continuing.' };
        }
        if (this.isSaving) {
            return { isValid: false, missingFields, message: 'Wait for Save to finish before continuing.' };
        }
        if (this.loadError) {
            return { isValid: false, missingFields, message: this.loadError };
        }
        if (!this.hasSelectedPdf) {
            return { isValid: false, missingFields, message: 'A PDF must be loaded before continuing.' };
        }
        if (missingFields.length) {
            return {
                isValid: false,
                missingFields,
                message: `Add these required fields before continuing: ${missingFields.join(', ')}.`
            };
        }
        if (!this.preparedEnvelopeId || !this.lastSavedPlacementSignature) {
            return { isValid: false, missingFields, message: 'Click Save before continuing.' };
        }
        if (this.getPlacementSignature() !== this.lastSavedPlacementSignature) {
            return { isValid: false, missingFields, message: 'Click Save again to save the latest field changes before continuing.' };
        }
        return { isValid: true, missingFields, message: 'Envelope is ready.' };
    }

    getMissingRequiredFieldTypes() {
        const presentFieldTypes = new Set(this.fields.map((field) => field.fieldType));
        return REQUIRED_FLOW_FIELD_TYPES.filter((fieldType) => !presentFieldTypes.has(fieldType));
    }

    getPlacementSignature() {
        return JSON.stringify(this.fields.map((field) => this.toPlacementPayload(field)));
    }

    dispatchFlowAttributeChange(name, value) {
        try {
            this.dispatchEvent(new FlowAttributeChangeEvent(name, value));
        } catch (error) {
            // Flow output events are only consumed when this runs on a Flow screen.
        }
    }

    handleViewportResize() {
        if (this.viewportResizeFrameId) {
            window.cancelAnimationFrame(this.viewportResizeFrameId);
        }
        this.viewportResizeFrameId = window.requestAnimationFrame(() => {
            this.viewportResizeFrameId = null;
            this.updateResponsiveHeight();
        });
    }

    updateResponsiveHeight() {
        const configuredHeight = this.configuredViewerHeight;
        const viewportHeight = window.visualViewport?.height || window.innerHeight || configuredHeight;
        const workspace = this.template.querySelector('.prepare-workspace');
        const anchorElement = workspace || this.template.host;
        const anchorRect = anchorElement?.getBoundingClientRect ? anchorElement.getBoundingClientRect() : null;
        const availableHeight = anchorRect ? viewportHeight - anchorRect.top - VIEWPORT_BOTTOM_PADDING : configuredHeight;
        const nextHeight = Math.round(Math.max(configuredHeight, MIN_VIEWER_HEIGHT, availableHeight));
        if (nextHeight !== this.responsiveViewerHeight) {
            this.responsiveViewerHeight = nextHeight;
        }
    }

    get pagesWithFields() {
        return this.pages.map((page) => {
            const pageFields = this.fields
                .filter((field) => field.pageNumber === page.pageNumber)
                .map((field) => ({
                    ...field,
                    className: `placed-field ${field.clientId === this.selectedFieldId ? 'selected' : ''} type-${field.fieldType.toLowerCase()}`,
                    displayLabel: field.label || field.fieldType,
                    style: [
                        `left: ${field.xPercent * 100}%`,
                        `top: ${field.yPercent * 100}%`,
                        `width: ${field.widthPercent * 100}%`,
                        `height: ${field.heightPercent * 100}%`
                    ].join(';')
                }));
            return { ...page, fields: pageFields };
        });
    }

    async initialize() {
        this.isLoading = true;
        this.loadError = null;
        try {
            if (!this.effectiveParentRecordId) {
                throw new Error('Parent Record Id is required. Put this component on a record page or pass recordId from Flow.');
            }
            if (this.contentDocumentId) {
                this.selectedContentDocumentId = this.contentDocumentId;
                await this.loadSelectedPdf();
            }
        } catch (error) {
            this.loadError = this.normalizeError(error);
        } finally {
            this.isLoading = false;
            this.syncFlowValidationOutputs();
        }
    }

    async loadSelectedPdf() {
        this.isLoading = true;
        this.loadError = null;
        this.fields = [];
        this.pages = [];
        this.pageImageDataCache = new Map();
        this.preparedEnvelopeId = null;
        this.lastSavedPlacementSignature = null;
        this.syncFlowValidationOutputs();
        try {
            if (!this.activeContentDocumentId) {
                return;
            }
            this.loadingMessage = 'Loading PDF information...';
            this.pdfInfo = await this.withTimeout(
                getPdfDocumentInfo({ contentDocumentId: this.activeContentDocumentId }),
                20000,
                'Loading PDF information'
            );
            this.selectedContentVersionId = this.pdfInfo.contentVersionId;
            this.loadingMessage = 'Counting PDF pages...';
            await this.updatePageCountFromPdfJs();
            this.loadingMessage = 'Preparing page previews...';
            this.initializeRenditionPreview();
            this.loadingMessage = 'Loading saved field placements...';
            await this.withTimeout(this.loadExistingPlacements(), 20000, 'Loading saved field placements');
            this.loadingMessage = 'Rendering PDF pages...';
            await this.renderAllPages();
        } catch (error) {
            this.loadError = this.normalizeError(error);
        } finally {
            this.isLoading = false;
            this.syncFlowValidationOutputs();
        }
    }

    initializeRenditionPreview() {
        const pageCount = Math.max(Number(this.pdfInfo?.pageCount) || 1, 1);
        this.pages = Array.from({ length: pageCount }, (_, index) => ({
            pageNumber: index + 1,
            pageIndex: index,
            renditionUrl: this.buildRenditionUrl('SVGZ', index),
            fallbackRenditionUrl: this.buildRenditionUrl('THUMB720BY480', index),
            hasTriedFallback: false,
            altText: `PDF page ${index + 1}`
        }));
    }

    async updatePageCountFromPdfJs() {
        try {
            await this.withTimeout(this.detectPdfPageCountFromPdfJs(), 12000, 'Counting PDF pages');
        } catch (error) {}
    }

    async detectPdfPageCountFromPdfJs() {
        await this.ensurePdfJsLoaded();
        if (!window.pdfjsLib || !this.pdfInfo?.contentVersionId) {
            return;
        }
        const loadingTask = window.pdfjsLib.getDocument({
            url: `/sfc/servlet.shepherd/version/download/${this.pdfInfo.contentVersionId}`,
            withCredentials: true
        });
        const pdfDocument = await loadingTask.promise;
        try {
            const pageCount = Number(pdfDocument.numPages);
            if (Number.isFinite(pageCount) && pageCount > 0) {
                this.pdfInfo = { ...this.pdfInfo, pageCount };
            }
        } finally {
            if (pdfDocument && typeof pdfDocument.destroy === 'function') {
                pdfDocument.destroy();
            }
        }
    }

    async ensurePdfJsLoaded() {
        if (window.pdfjsLib) {
            window.pdfjsLib.GlobalWorkerOptions.workerSrc = `${PDF_JS}/pdf.worker.min.js`;
            return;
        }
        if (!this.pdfJsLoadPromise) {
            this.pdfJsLoadPromise = loadScript(this, `${PDF_JS}/pdf.min.js`).then(() => {
                if (window.pdfjsLib) {
                    window.pdfjsLib.GlobalWorkerOptions.workerSrc = `${PDF_JS}/pdf.worker.min.js`;
                }
            });
        }
        await this.pdfJsLoadPromise;
    }

    buildRenditionUrl(rendition, pageIndex) {
        const params = new URLSearchParams({
            rendition,
            versionId: this.pdfInfo.contentVersionId,
            operationContext: 'CHATTER',
            page: String(pageIndex)
        });
        return `/sfc/servlet.shepherd/version/renditionDownload?${params.toString()}`;
    }

    async loadExistingPlacements() {
        const existingPlacements = await getPlacements({
            parentRecordId: this.effectiveParentRecordId,
            contentDocumentId: this.activeContentDocumentId
        });
        this.fields = existingPlacements.map((placement) => ({
            clientId: this.newClientId(),
            serverId: placement.id,
            fieldType: placement.fieldType,
            pageNumber: placement.pageNumber,
            xPercent: Number(placement.xPercent),
            yPercent: Number(placement.yPercent),
            widthPercent: Number(placement.widthPercent),
            heightPercent: Number(placement.heightPercent),
            signerNumber: placement.signerNumber || 1,
            required: placement.required !== false,
            label: placement.label || placement.fieldType
        }));
    }

    async renderAllPages() {
        await this.withTimeout(this.waitForRender(), 10000, 'Waiting for pages to render');
        this.pageDimensions = new Map();
        for (const page of this.pages) {
            this.configureRenditionPage(page.pageNumber, 612, 792);
            this.pageDimensions.set(page.pageNumber, { width: 612, height: 792 });
        }
    }

    configureRenditionPage(pageNumber, pdfWidth, pdfHeight) {
        const pageShell = this.template.querySelector(`section[data-page-number="${pageNumber}"]`);
        if (!pageShell) {
            return;
        }
        pageShell.style.width = `${pdfWidth * this.zoom}px`;
        pageShell.style.height = `${pdfHeight * this.zoom}px`;
    }

    handleRenditionLoad(event) {
        const image = event.currentTarget;
        const pageNumber = Number(image.dataset.pageNumber);
        const naturalWidth = image.naturalWidth || 612;
        const naturalHeight = image.naturalHeight || 792;
        const pdfWidth = 612;
        const pdfHeight = Math.round((pdfWidth * naturalHeight) / naturalWidth);
        this.pageImageDataCache.delete(pageNumber);
        this.configureRenditionPage(pageNumber, pdfWidth, pdfHeight);
        this.pageDimensions.set(pageNumber, { width: pdfWidth, height: pdfHeight });
    }

    handleRenditionError(event) {
        const pageNumber = Number(event.currentTarget.dataset.pageNumber);
        this.pages = this.pages.map((page) => {
            if (page.pageNumber !== pageNumber || page.hasTriedFallback) {
                return page;
            }
            return { ...page, renditionUrl: page.fallbackRenditionUrl, hasTriedFallback: true };
        });
    }

    handlePaletteDragStart(event) {
        this.draggedFieldType = event.currentTarget.dataset.fieldType;
        event.dataTransfer.setData('text/plain', this.draggedFieldType);
        event.dataTransfer.effectAllowed = 'copy';
    }

    handlePaletteClick(event) {
        this.pendingFieldType = event.currentTarget.dataset.fieldType;
    }

    handlePageDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'copy';
    }

    handlePageDrop(event) {
        event.preventDefault();
        const fieldType = event.dataTransfer.getData('text/plain') || this.draggedFieldType;
        this.addFieldFromEvent(fieldType, event);
        this.draggedFieldType = null;
    }

    handlePageClick(event) {
        if (!this.pendingFieldType) {
            if (!event.target.closest('.placed-field')) {
                this.selectedFieldId = null;
            }
            return;
        }
        this.addFieldFromEvent(this.pendingFieldType, event);
        this.pendingFieldType = null;
    }

    addFieldFromEvent(fieldType, event) {
        if (!fieldType) {
            return;
        }
        const pageShell = event.currentTarget;
        const pageNumber = Number(pageShell.dataset.pageNumber);
        const rect = pageShell.getBoundingClientRect();
        const config = FIELD_TYPES.find((item) => item.value === fieldType);
        const widthPercent = config ? config.width : 0.2;
        const heightPercent = config ? config.height : 0.04;
        const anchorXPercent = this.clamp((event.clientX - rect.left) / rect.width, 0, 1);
        const anchorYPercent = this.clamp((event.clientY - rect.top) / rect.height, 0, 1);
        const xPercent = this.clamp(anchorXPercent - widthPercent / 2, 0, 1 - widthPercent);
        const yPercent = this.clamp(anchorYPercent - heightPercent / 2, 0, 1 - heightPercent);
        const field = this.autoFitFieldToLine({
            clientId: this.newClientId(), fieldType, pageNumber, xPercent, yPercent,
            widthPercent, heightPercent, signerNumber: 1, required: config ? config.defaultRequired !== false : true, label: fieldType
        }, pageShell, anchorXPercent, anchorYPercent);
        this.fields = [...this.fields, field];
        this.selectedFieldId = field.clientId;
        this.syncFlowValidationOutputs();
    }

    handleFieldClick(event) {
        event.stopPropagation();
        this.selectedFieldId = event.currentTarget.dataset.clientId;
    }

    handleFieldDeletePointerDown(event) {
        event.preventDefault();
        event.stopPropagation();
    }

    handleFieldDeleteClick(event) {
        event.preventDefault();
        event.stopPropagation();
        const clientId = event.currentTarget.dataset.clientId;
        this.fields = this.fields.filter((field) => field.clientId !== clientId);
        if (this.selectedFieldId === clientId) {
            this.selectedFieldId = null;
        }
        if (this.pointerState && this.pointerState.clientId === clientId) {
            this.pointerState = null;
            this.removePointerListeners();
        }
        this.syncFlowValidationOutputs();
    }

    handleFieldPointerDown(event) {
        event.preventDefault();
        event.stopPropagation();
        const clientId = event.currentTarget.dataset.clientId;
        const field = this.fields.find((item) => item.clientId === clientId);
        const pageShell = this.template.querySelector(`section[data-page-number="${field.pageNumber}"]`);
        const rect = pageShell.getBoundingClientRect();
        this.selectedFieldId = clientId;
        this.pointerState = { action: 'move', clientId, startX: event.clientX, startY: event.clientY, startField: { ...field }, pageRect: rect, hasMoved: false };
        this.addPointerListeners();
    }

    handleResizePointerDown(event) {
        event.preventDefault();
        event.stopPropagation();
        const clientId = event.currentTarget.dataset.clientId;
        const field = this.fields.find((item) => item.clientId === clientId);
        const pageShell = this.template.querySelector(`section[data-page-number="${field.pageNumber}"]`);
        const rect = pageShell.getBoundingClientRect();
        this.selectedFieldId = clientId;
        this.pointerState = { action: 'resize', clientId, startX: event.clientX, startY: event.clientY, startField: { ...field }, pageRect: rect, hasMoved: false };
        this.addPointerListeners();
    }

    handlePointerMove(event) {
        if (!this.pointerState) {
            return;
        }
        const deltaXPercent = (event.clientX - this.pointerState.startX) / this.pointerState.pageRect.width;
        const deltaYPercent = (event.clientY - this.pointerState.startY) / this.pointerState.pageRect.height;
        const movedPixels = Math.abs(event.clientX - this.pointerState.startX) + Math.abs(event.clientY - this.pointerState.startY);
        if (!this.pointerState.hasMoved && movedPixels <= DRAG_THRESHOLD_PIXELS) {
            return;
        }
        this.pointerState.hasMoved = true;
        this.fields = this.fields.map((field) => {
            if (field.clientId !== this.pointerState.clientId) {
                return field;
            }
            if (this.pointerState.action === 'move') {
                return {
                    ...field,
                    xPercent: this.clamp(this.pointerState.startField.xPercent + deltaXPercent, 0, 1 - field.widthPercent),
                    yPercent: this.clamp(this.pointerState.startField.yPercent + deltaYPercent, 0, 1 - field.heightPercent)
                };
            }
            return {
                ...field,
                widthPercent: this.clamp(this.pointerState.startField.widthPercent + deltaXPercent, MIN_FIELD_WIDTH, 1 - this.pointerState.startField.xPercent),
                heightPercent: this.clamp(this.pointerState.startField.heightPercent + deltaYPercent, MIN_FIELD_HEIGHT, 1 - this.pointerState.startField.yPercent)
            };
        });
    }

    handlePointerUp() {
        const state = this.pointerState;
        if (this.pointerState && !this.pointerState.hasMoved) {
            this.selectedFieldId = this.pointerState.clientId;
        }
        this.pointerState = null;
        this.removePointerListeners();
        if (state && state.action === 'move' && state.hasMoved) {
            this.autoFitMovedFieldToLine(state.clientId);
        }
        if (state && state.hasMoved) {
            this.syncFlowValidationOutputs();
        }
    }

    addPointerListeners() {
        window.addEventListener('pointermove', this.boundHandlePointerMove);
        window.addEventListener('pointerup', this.boundHandlePointerUp);
        window.addEventListener('pointercancel', this.boundHandlePointerCancel);
        window.addEventListener('blur', this.boundHandlePointerCancel);
    }

    removePointerListeners() {
        window.removeEventListener('pointermove', this.boundHandlePointerMove);
        window.removeEventListener('pointerup', this.boundHandlePointerUp);
        window.removeEventListener('pointercancel', this.boundHandlePointerCancel);
        window.removeEventListener('blur', this.boundHandlePointerCancel);
    }

    handleSelectedLabelChange(event) {
        this.updateSelectedField({ label: event.detail.value });
    }

    handleSelectedRequiredChange(event) {
        this.updateSelectedField({ required: event.detail.checked });
    }

    updateSelectedField(changes) {
        if (!this.selectedFieldId) {
            return;
        }
        this.fields = this.fields.map((field) => (field.clientId === this.selectedFieldId ? { ...field, ...changes } : field));
        this.syncFlowValidationOutputs();
    }

    autoFitMovedFieldToLine(clientId) {
        const field = this.fields.find((item) => item.clientId === clientId);
        if (!field) {
            return;
        }
        const pageShell = this.template.querySelector(`section[data-page-number="${field.pageNumber}"]`);
        if (!pageShell) {
            return;
        }
        this.fields = this.fields.map((item) => {
            if (item.clientId !== clientId) {
                return item;
            }
            return this.autoFitFieldToLine(
                item,
                pageShell,
                item.xPercent + item.widthPercent / 2,
                item.yPercent + item.heightPercent / 2
            );
        });
    }

    autoFitFieldToLine(field, pageShell, anchorXPercent, anchorYPercent) {
        if (!AUTO_FIT_FIELD_TYPES.has(field.fieldType)) {
            return field;
        }
        const line = this.detectHorizontalLine(pageShell, field.pageNumber, anchorXPercent, anchorYPercent);
        if (!line) {
            return field;
        }
        const fittedWidth = this.clamp(line.widthPercent, MIN_FIELD_WIDTH, 1);
        return {
            ...field,
            xPercent: this.clamp(line.xPercent, 0, 1 - fittedWidth),
            widthPercent: fittedWidth
        };
    }

    detectHorizontalLine(pageShell, pageNumber, anchorXPercent, anchorYPercent) {
        const pageImage = this.getPageImageData(pageShell, pageNumber);
        if (!pageImage) {
            return null;
        }
        const width = pageImage.width;
        const height = pageImage.height;
        const anchorX = this.clamp(Math.round(anchorXPercent * width), 0, width - 1);
        const anchorY = this.clamp(Math.round(anchorYPercent * height), 0, height - 1);
        const searchRadius = Math.max(6, Math.round(height * LINE_SCAN_Y_PERCENT));
        let bestCandidate = null;
        for (let y = Math.max(0, anchorY - searchRadius); y <= Math.min(height - 1, anchorY + searchRadius); y += 1) {
            const candidate = this.findLineRunOnRow(pageImage, y, anchorX);
            if (!candidate) {
                continue;
            }
            const verticalDistance = Math.abs(y - anchorY);
            const score = candidate.width - verticalDistance * 3 + candidate.darkPixels * 0.2;
            if (!bestCandidate || score > bestCandidate.score) {
                bestCandidate = { ...candidate, y, score };
            }
        }
        if (!bestCandidate) {
            return null;
        }
        return {
            xPercent: bestCandidate.left / width,
            widthPercent: (bestCandidate.right - bestCandidate.left + 1) / width
        };
    }

    getPageImageData(pageShell, pageNumber) {
        const image = pageShell.querySelector('img.pdf-rendition');
        if (!image || !image.complete || !image.naturalWidth || !image.naturalHeight) {
            return null;
        }
        const cached = this.pageImageDataCache.get(pageNumber);
        const imageSrc = image.currentSrc || image.src;
        if (cached && cached.src === imageSrc && cached.width === image.naturalWidth && cached.height === image.naturalHeight) {
            return cached;
        }
        try {
            const canvas = document.createElement('canvas');
            canvas.width = image.naturalWidth;
            canvas.height = image.naturalHeight;
            const context = canvas.getContext('2d', { willReadFrequently: true });
            if (!context) {
                return null;
            }
            context.drawImage(image, 0, 0, canvas.width, canvas.height);
            const imageData = context.getImageData(0, 0, canvas.width, canvas.height);
            const pageImage = {
                src: imageSrc,
                width: canvas.width,
                height: canvas.height,
                data: imageData.data
            };
            this.pageImageDataCache.set(pageNumber, pageImage);
            return pageImage;
        } catch (error) {
            return null;
        }
    }

    findLineRunOnRow(pageImage, y, anchorX) {
        const width = pageImage.width;
        const maxGap = Math.max(3, Math.round(width * LINE_MAX_GAP_PERCENT));
        const startGap = Math.max(maxGap, Math.round(width * LINE_START_GAP_PERCENT));
        const minWidth = Math.max(28, Math.round(width * LINE_MIN_WIDTH_PERCENT));
        const nearLeft = Math.max(0, anchorX - startGap);
        const nearRight = Math.min(width - 1, anchorX + startGap);
        let nearestInkX = null;
        for (let x = nearLeft; x <= nearRight; x += 1) {
            if (this.isLinePixel(pageImage, x, y)) {
                if (nearestInkX === null || Math.abs(x - anchorX) < Math.abs(nearestInkX - anchorX)) {
                    nearestInkX = x;
                }
            }
        }
        if (nearestInkX === null) {
            return null;
        }

        const leftResult = this.scanLineEdge(pageImage, y, nearestInkX, -1, maxGap);
        const rightResult = this.scanLineEdge(pageImage, y, nearestInkX, 1, maxGap);
        const left = leftResult.edge;
        const right = rightResult.edge;
        const runWidth = right - left + 1;
        const darkPixels = leftResult.darkPixels + rightResult.darkPixels - 1;
        const density = darkPixels / Math.max(1, runWidth);
        if (runWidth < minWidth || density < 0.14) {
            return null;
        }
        return { left, right, width: runWidth, darkPixels };
    }

    scanLineEdge(pageImage, y, startX, direction, maxGap) {
        const width = pageImage.width;
        let edge = startX;
        let darkPixels = 0;
        let gap = 0;
        for (let x = startX; x >= 0 && x < width; x += direction) {
            if (this.isLinePixel(pageImage, x, y)) {
                edge = x;
                darkPixels += 1;
                gap = 0;
            } else {
                gap += 1;
                if (gap > maxGap) {
                    break;
                }
            }
        }
        return { edge, darkPixels };
    }

    isLinePixel(pageImage, x, y) {
        const index = (y * pageImage.width + x) * 4;
        const alpha = pageImage.data[index + 3];
        if (alpha < 24) {
            return false;
        }
        const red = pageImage.data[index];
        const green = pageImage.data[index + 1];
        const blue = pageImage.data[index + 2];
        const luma = red * 0.299 + green * 0.587 + blue * 0.114;
        return luma < LINE_LUMA_THRESHOLD;
    }

    async handleZoomOut() {
        this.zoom = Math.max(0.75, this.zoom - 0.1);
        await this.renderAllPages();
    }

    async handleZoomIn() {
        this.zoom = Math.min(2.25, this.zoom + 0.1);
        await this.renderAllPages();
    }

    async handleSave() {
        this.clearSaveNotice();
        if (!this.fields.length) {
            this.syncFlowValidationOutputs();
            this.showSaveMessage('No fields to save', 'There are no fields to save.', 'warning');
            return;
        }
        const missingFields = this.getMissingRequiredFieldTypes();
        if (missingFields.length) {
            this.syncFlowValidationOutputs();
            this.showSaveMessage(
                'Required fields missing',
                `Add these required fields before saving: ${missingFields.join(', ')}.`,
                'warning'
            );
            return;
        }

        this.isSaving = true;
        try {
            const placements = this.fields.map((field) => this.toPlacementPayload(field));
            const result = await savePlacements({
                parentRecordId: this.effectiveParentRecordId,
                contentDocumentId: this.activeContentDocumentId,
                contentVersionId: this.pdfInfo.contentVersionId,
                placementsJson: JSON.stringify(placements)
            });
            this.preparedEnvelopeId = result?.envelopeId || null;
            this.lastSavedPlacementSignature = this.getPlacementSignature();
            const message = result?.message || 'Envelope fields saved.';
            this.showSaveMessage('Fields saved', message, 'success');
        } catch (error) {
            this.showSaveMessage('Unable to save fields', this.normalizeError(error), 'error', 'sticky');
        } finally {
            this.isSaving = false;
            this.syncFlowValidationOutputs();
        }
    }

    showSaveMessage(title, message, variant = 'info', mode = 'dismissible') {
        this.saveNotice = { title, message, variant };
        this.handleViewportResize();
        try {
            this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
        } catch (error) {
            // Some Flow launch contexts do not host Salesforce toasts.
        }
        if (this.saveNoticeTimeoutId) {
            window.clearTimeout(this.saveNoticeTimeoutId);
            this.saveNoticeTimeoutId = null;
        }
        if (variant !== 'error' && mode !== 'sticky') {
            this.saveNoticeTimeoutId = window.setTimeout(() => {
                this.saveNotice = null;
                this.saveNoticeTimeoutId = null;
            }, 8000);
        }
    }

    clearSaveNotice(shouldUpdateHeight = true) {
        this.saveNotice = null;
        if (shouldUpdateHeight !== false) {
            this.handleViewportResize();
        }
        if (this.saveNoticeTimeoutId) {
            window.clearTimeout(this.saveNoticeTimeoutId);
            this.saveNoticeTimeoutId = null;
        }
    }

    toPlacementPayload(field) {
        const pageDimension = this.pageDimensions.get(field.pageNumber);
        const pdfWidth = pageDimension ? pageDimension.width : 612;
        const pdfHeight = pageDimension ? pageDimension.height : 792;
        return {
            fieldType: field.fieldType,
            pageNumber: field.pageNumber,
            xPercent: this.round(field.xPercent),
            yPercent: this.round(field.yPercent),
            widthPercent: this.round(field.widthPercent),
            heightPercent: this.round(field.heightPercent),
            signerNumber: field.signerNumber || 1,
            required: field.required !== false,
            label: field.label || field.fieldType,
            pdfX: this.round(field.xPercent * pdfWidth, 2),
            pdfY: this.round(pdfHeight - ((field.yPercent + field.heightPercent) * pdfHeight), 2),
            pdfWidth: this.round(field.widthPercent * pdfWidth, 2),
            pdfHeight: this.round(field.heightPercent * pdfHeight, 2)
        };
    }

    newClientId() {
        const value = `field-${this.nextClientId}`;
        this.nextClientId += 1;
        return value;
    }

    waitForRender() {
        return new Promise((resolve) => window.requestAnimationFrame(() => resolve()));
    }

    withTimeout(promise, milliseconds, label) {
        let timeoutId;
        const timeout = new Promise((resolve, reject) => {
            timeoutId = window.setTimeout(() => reject(new Error(`${label} timed out after ${Math.round(milliseconds / 1000)} seconds.`)), milliseconds);
        });
        return Promise.race([promise, timeout]).finally(() => window.clearTimeout(timeoutId));
    }

    clamp(value, min, max) {
        return Math.min(Math.max(value, min), max);
    }

    round(value, decimals = 8) {
        const factor = 10 ** decimals;
        return Math.round(Number(value) * factor) / factor;
    }

    normalizeError(error) {
        if (!error) {
            return 'Unknown error';
        }
        if (Array.isArray(error.body)) {
            return error.body.map((item) => item.message).join(', ');
        }
        if (error.body && error.body.message) {
            return error.body.message;
        }
        return error.message || String(error);
    }
}
