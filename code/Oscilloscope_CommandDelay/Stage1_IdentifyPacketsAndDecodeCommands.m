%% Stage1_IdentifyPacketsAndDecodeCommands.m
% OPENXSTIM SCALABLE STAGE 1
%
% Uses the SAME command decoding logic as the validated Script01:
%   thresholdBit -> rawCode -> removeShortRuns -> runsFromCode
%   -> classifyLegacyCodePair / transitionCodeLabel
%
% Stage 1 then identifies stimulation packets from the SEMANTIC commands:
%   zero_to_pos = packet start
%   neg_to_zero = packet end
%
% Only packets matching the full expected 20-pulse, 41-command sequence
% are retained for downstream processing.
%
% Incomplete edge packets remain documented for diagnostics, but they are
% excluded from Stage1SelectedCommandEvents.csv.
%
% Stage 1 deliberately does NOT perform:
%   CH3 gradient detection
%   command/response matching
%   delay estimation
%   normalization
%   passive-droop fitting
%   transfer-function fitting

clear;
clc;
close all;

%% ========================================================================
% USER SETTINGS
% ========================================================================

cfg = struct();

cfg.DATA_ROOT = ...
    fileparts(mfilename("fullpath")); % Put the CSV files in the same folder as this script.

cfg.ANALYSIS_FOLDER = ...
    fullfile(cfg.DATA_ROOT,"Matlab Analysis");

cfg.STAGE0_FILE = ...
    fullfile(cfg.ANALYSIS_FOLDER, ...
    "Stage0_CaptureIndex","CaptureIndex.mat");

cfg.STAGE1_OUTPUT_FOLDER = ...
    fullfile(cfg.ANALYSIS_FOLDER, ...
    "Stage1_PacketClassification");

cfg.EXPECTED_PULSE_COUNT = 20;

% Matches the already validated Script01 logic for the present captures.
% Change to "transition_code" only if later firmware requires it.
cfg.COMMAND_ENCODING_MODE = "legacy_state_pair";

cfg.D5_CHANNEL = 1;
cfg.D8_CHANNEL = 2;
cfg.OUTPUT_CHANNEL = 3;

cfg.R_LOAD_OHM = 1000;

% NaN = robust automatic midpoint, same as Script01.
cfg.D5_THRESHOLD_V = NaN;
cfg.D8_THRESHOLD_V = NaN;

% Physical-time setting, converted using each capture's own Ts.
cfg.MIN_DEBUG_DWELL_US = 5;

% Stored for the next stage only. These do NOT determine packet validity.
cfg.DOWNSTREAM_CONTEXT_BEFORE_MS = 2.0;
cfg.DOWNSTREAM_CONTEXT_AFTER_MS = 2.5;

cfg.SAVE_PLOTS = true;
cfg.SHOW_FIGURES = true;
cfg.FIGURE_RESOLUTION_DPI = 180;
cfg.MAX_PLOT_POINTS = 80000;

%% ========================================================================
% LOAD STAGE 0
% ========================================================================

if ~isfile(cfg.STAGE0_FILE)
    error("Stage 0 file not found:\n%s",cfg.STAGE0_FILE);
end

if ~isfolder(cfg.STAGE1_OUTPUT_FOLDER)
    mkdir(cfg.STAGE1_OUTPUT_FOLDER);
end

S0 = load(cfg.STAGE0_FILE);

if isfield(S0,"captureIndex")
    captureIndex = S0.captureIndex;
elseif isfield(S0,"CaptureIndex")
    captureIndex = S0.CaptureIndex;
else
    error("Could not find captureIndex in Stage 0 MAT file.");
end

nCaptures = numel(captureIndex);

expectedPacket = buildExpectedPacket(cfg.EXPECTED_PULSE_COUNT);

fprintf("\n============================================================\n");
fprintf("OPENXSTIM STAGE 1: PACKET IDENTIFICATION + COMMAND DECODING\n");
fprintf("============================================================\n");
fprintf("Captures found           : %d\n",nCaptures);
fprintf("Encoding mode            : %s\n",cfg.COMMAND_ENCODING_MODE);
fprintf("Pulse count              : %d\n",cfg.EXPECTED_PULSE_COUNT);
fprintf("Expected events / packet : %d\n",height(expectedPacket));
fprintf("Minimum debug dwell      : %.3f us\n",cfg.MIN_DEBUG_DWELL_US);

%% ========================================================================
% MASTER CONTAINERS
% ========================================================================

captureSummaryParts = cell(nCaptures,1);
selectedEventParts = cell(nCaptures,1);
packetCandidateParts = cell(nCaptures,1);
resultFiles = strings(nCaptures,1);

%% ========================================================================
% PROCESS CAPTURES ONE AT A TIME
% ========================================================================

for c = 1:nCaptures

    fprintf("\n------------------------------------------------------------\n");
    fprintf("CAPTURE %d / %d\n",c,nCaptures);
    fprintf("------------------------------------------------------------\n");

    meta = captureIndex(c);

    captureID = getNumericMeta(meta,["captureID","CaptureID"],c);
    attemptNumber = getNumericMeta(meta, ...
        ["attemptNumber","AttemptNumber","Attempt"],NaN);
    commandCurrent_mA = getNumericMeta(meta, ...
        ["commandCurrent_mA","CommandCurrent_mA"],NaN);
    captureWithinAttempt = getNumericMeta(meta, ...
        ["captureWithinAttempt","CaptureWithinAttempt"],NaN);
    fileName = getStringMeta(meta,["fileName","FileName"],"");
    csvPath = getStringMeta(meta, ...
        ["filePath","FullPath","fullPath","csvPath"],"");

    try

        %% ----------------------------------------------------------------
        % FULL-RESOLUTION IMPORT
        % -----------------------------------------------------------------

        if strlength(csvPath)==0 || ~isfile(csvPath)
            error("Original CSV not found: %s",csvPath);
        end

        [data,t,t0,Ts,header] = loadRigolMemoryCSV(csvPath);

        Fs = 1/Ts;

        if size(data,2) < max( ...
                [cfg.D5_CHANNEL,cfg.D8_CHANNEL,cfg.OUTPUT_CHANNEL])
            error("CSV does not contain all requested channels.");
        end

        d5V = data(:,cfg.D5_CHANNEL);
        d8V = data(:,cfg.D8_CHANNEL);
        outputV = data(:,cfg.OUTPUT_CHANNEL);

        currentRaw_mA = 1000*outputV/cfg.R_LOAD_OHM;

        fprintf("Capture ID  : %d\n",captureID);
        fprintf("Attempt     : %.0f\n",attemptNumber);
        fprintf("Command     : %.3f mA\n",commandCurrent_mA);
        fprintf("File        : %s\n",csvPath);
        fprintf("Samples     : %d\n",size(data,1));
        fprintf("Fs          : %.6f MSa/s\n",Fs/1e6);
        fprintf("Duration    : %.3f ms\n",(t(end)-t(1))*1e3);

        %% =================================================================
        % PART A: EXACT SCRIPT01 COMMAND DECODING LOGIC
        % =================================================================

        [d5Bit,d5Threshold] = thresholdBit(d5V,cfg.D5_THRESHOLD_V);
        [d8Bit,d8Threshold] = thresholdBit(d8V,cfg.D8_THRESHOLD_V);

        rawCode = uint8(2*d8Bit+d5Bit);

        minDebugSamples = ...
            max(2,round(cfg.MIN_DEBUG_DWELL_US*1e-6/Ts));

        cleanCode = removeShortRuns(rawCode,minDebugSamples);

        samplesChangedByCleanup = nnz(cleanCode~=rawCode);

        [cmdRunStart,~,cmdRunCode] = runsFromCode(cleanCode);

        commandIdx = cmdRunStart(2:end);
        commandTime_s = t(commandIdx);

        fromCode = double(cmdRunCode(1:end-1));
        toCode = double(cmdRunCode(2:end));

        nCommands = numel(commandIdx);

        commandClass = strings(nCommands,1);
        commandContext = strings(nCommands,1);

        for e = 1:nCommands

            if cfg.COMMAND_ENCODING_MODE=="legacy_state_pair"

                [commandClass(e),commandContext(e)] = ...
                    classifyLegacyCodePair(fromCode(e),toCode(e));

            elseif cfg.COMMAND_ENCODING_MODE=="transition_code"

                commandClass(e) = transitionCodeLabel(toCode(e));
                commandContext(e) = sprintf("new_code_%d",toCode(e));

            else

                error("Unknown COMMAND_ENCODING_MODE.");
            end
        end

        commandEvent = (1:nCommands).';
        commandTime_ms = commandTime_s*1e3;

        toD5 = double(bitand(uint8(toCode),uint8(1)));
        toD8 = double(bitshift(bitand(uint8(toCode),uint8(2)),-1));

        allCommandTable = table( ...
            commandEvent,commandIdx,commandTime_s,commandTime_ms, ...
            fromCode,toCode,toD8,toD5,commandClass,commandContext, ...
            'VariableNames',{ ...
            'GlobalCommandEvent','SampleIndex','CommandTime_s', ...
            'CommandTime_ms','FromCode','ToCode','D8','D5', ...
            'TransitionClass','Context'});

        fprintf("\nCOMMAND DETECTION\n");
        fprintf("D5 threshold             : %.6f V\n",d5Threshold);
        fprintf("D8 threshold             : %.6f V\n",d8Threshold);
        fprintf("Minimum debug dwell      : %d samples\n",minDebugSamples);
        fprintf("Samples changed cleanup  : %d\n",samplesChangedByCleanup);
        fprintf("Decoded command events   : %d\n",nCommands);
        fprintf("0 -> +I                  : %d\n", ...
            nnz(commandClass=="zero_to_pos"));
        fprintf("+I -> -I                 : %d\n", ...
            nnz(commandClass=="pos_to_neg"));
        fprintf("-I -> +I                 : %d\n", ...
            nnz(commandClass=="neg_to_pos"));
        fprintf("-I -> 0                  : %d\n", ...
            nnz(commandClass=="neg_to_zero"));
        fprintf("Unexpected               : %d\n", ...
            nnz(commandClass=="unexpected"));

        %% =================================================================
        % PART B: SEMANTIC PACKET IDENTIFICATION
        % =================================================================

        packetTable = identifySemanticPackets( ...
            allCommandTable,expectedPacket);

        startRows = find(commandClass=="zero_to_pos");

        if isempty(startRows)
            leadingPartialEventCount = nCommands;
        else
            leadingPartialEventCount = startRows(1)-1;
        end

        leadingPartialPresent = leadingPartialEventCount>0;

        nPacketCandidates = height(packetTable);
        nCompletePackets = nnz(packetTable.IsComplete);
        nIncompleteCandidates = nnz(~packetTable.IsComplete);

        partialFragmentCount = ...
            nIncompleteCandidates + double(leadingPartialPresent);

        fprintf("\nPACKET IDENTIFICATION\n");
        fprintf("Packet start markers      : %d\n",numel(startRows));
        fprintf("Packet candidates         : %d\n",nPacketCandidates);
        fprintf("Complete packets          : %d\n",nCompletePackets);
        fprintf("Incomplete candidates     : %d\n",nIncompleteCandidates);
        fprintf("Leading partial fragment  : %s\n",yesNo(leadingPartialPresent));

        %% =================================================================
        % PART C: SELECT COMPLETE PACKET
        % =================================================================

        selectedPacketRow = NaN;
        selectedPacketCandidate = NaN;
        selectedCommandTable = table();

        stage1Status = "FAIL";
        stage1Message = "No complete packet found.";

        if nCompletePackets>0

            completeRows = find(packetTable.IsComplete);

            if numel(completeRows)==1

                selectedPacketRow = completeRows(1);
                stage1Status = "PASS";
                stage1Message = "Exactly one complete packet found.";

            else

                captureMid_s = 0.5*(t(1)+t(end));

                [~,ii] = min(abs( ...
                    packetTable.MidTime_s(completeRows)-captureMid_s));

                selectedPacketRow = completeRows(ii);
                stage1Status = "WARNING";
                stage1Message = sprintf( ...
                    "%d complete packets found; selected the one nearest capture midpoint.", ...
                    numel(completeRows));
            end

            selectedPacketCandidate = ...
                packetTable.PacketCandidate(selectedPacketRow);

            packetTable.IsSelected(:) = false;
            packetTable.IsSelected(selectedPacketRow) = true;

            firstEvent = ...
                packetTable.StartGlobalEvent(selectedPacketRow);

            lastEvent = ...
                packetTable.EndGlobalEvent(selectedPacketRow);

            selectedCommandTable = ...
                allCommandTable(firstEvent:lastEvent,:);

            if height(selectedCommandTable)~=height(expectedPacket)
                error("Selected packet length does not match expected packet.");
            end

            selectedCommandTable.EventNumberWithinPacket = ...
                expectedPacket.EventNumberWithinPacket;

            selectedCommandTable.PulseNumber = ...
                expectedPacket.PulseNumber;

            selectedCommandTable.ExpectedTransitionClass = ...
                expectedPacket.TransitionClass;

            selectedCommandTable.PacketCandidate = ...
                repmat(selectedPacketCandidate, ...
                height(selectedCommandTable),1);

            selectedCommandTable.CaptureID = ...
                repmat(captureID,height(selectedCommandTable),1);

            selectedCommandTable.AttemptNumber = ...
                repmat(attemptNumber,height(selectedCommandTable),1);

            selectedCommandTable.CommandCurrent_mA = ...
                repmat(commandCurrent_mA,height(selectedCommandTable),1);

            selectedCommandTable.CaptureWithinAttempt = ...
                repmat(captureWithinAttempt,height(selectedCommandTable),1);

            selectedCommandTable = movevars( ...
                selectedCommandTable, ...
                {'CaptureID','AttemptNumber','CommandCurrent_mA', ...
                'CaptureWithinAttempt','PacketCandidate', ...
                'EventNumberWithinPacket','PulseNumber'}, ...
                'Before',1);
        end

        %% =================================================================
        % PART D: PACKET BOUNDS FOR STAGE 2
        % =================================================================

        selectedPacketStart_s = NaN;
        selectedPacketEnd_s = NaN;
        selectedPacketDuration_ms = NaN;
        selectedPacketMidpoint_ms = NaN;
        downstreamWindowStart_s = NaN;
        downstreamWindowEnd_s = NaN;

        if isfinite(selectedPacketRow)

            selectedPacketStart_s = ...
                packetTable.StartTime_s(selectedPacketRow);

            selectedPacketEnd_s = ...
                packetTable.EndTime_s(selectedPacketRow);

            selectedPacketDuration_ms = ...
                (selectedPacketEnd_s-selectedPacketStart_s)*1e3;

            selectedPacketMidpoint_ms = ...
                packetTable.MidTime_s(selectedPacketRow)*1e3;

            downstreamWindowStart_s = max( ...
                t(1), ...
                selectedPacketStart_s ...
                - cfg.DOWNSTREAM_CONTEXT_BEFORE_MS*1e-3);

            downstreamWindowEnd_s = min( ...
                t(end), ...
                selectedPacketEnd_s ...
                + cfg.DOWNSTREAM_CONTEXT_AFTER_MS*1e-3);
        end

        %% =================================================================
        % PART E: PER-CAPTURE OUTPUT
        % =================================================================

        captureFolder = fullfile( ...
            cfg.STAGE1_OUTPUT_FOLDER, ...
            sprintf("Capture_%03d",captureID));

        if ~isfolder(captureFolder)
            mkdir(captureFolder);
        end

        packetCsvTable = addPacketMetadata( ...
            packetTable,captureID,attemptNumber, ...
            commandCurrent_mA,captureWithinAttempt);

        writetable(allCommandTable, ...
            fullfile(captureFolder,"01_AllDecodedCommands.csv"));

        if ~isempty(packetCsvTable)
            writetable(packetCsvTable, ...
                fullfile(captureFolder,"02_PacketCandidates.csv"));
        end

        if ~isempty(selectedCommandTable)
            writetable(selectedCommandTable, ...
                fullfile(captureFolder, ...
                "03_SelectedCompletePacketCommands.csv"));
        end

        result = struct();

        result.processingStage = "Stage1_PacketClassification";

        result.captureID = captureID;
        result.attemptNumber = attemptNumber;
        result.commandCurrent_mA = commandCurrent_mA;
        result.captureWithinAttempt = captureWithinAttempt;

        result.fileName = fileName;
        result.csvPath = csvPath;

        result.header = header;
        result.t0_s = t0;
        result.Ts_s = Ts;
        result.Fs_Hz = Fs;
        result.nSamples = numel(t);
        result.captureDuration_s = t(end)-t(1);

        result.commandEncodingMode = cfg.COMMAND_ENCODING_MODE;

        result.d5Threshold_V = d5Threshold;
        result.d8Threshold_V = d8Threshold;

        result.minDebugDwell_us = cfg.MIN_DEBUG_DWELL_US;
        result.minDebugDwell_samples = minDebugSamples;
        result.samplesChangedByCleanup = samplesChangedByCleanup;

        result.allCommandTable = allCommandTable;
        result.packetTable = packetTable;

        result.leadingPartialPresent = leadingPartialPresent;
        result.leadingPartialEventCount = leadingPartialEventCount;

        % THIS is the downstream interface.
        result.selectedPacketCandidate = selectedPacketCandidate;
        result.selectedCommandTable = selectedCommandTable;

        result.selectedPacketStart_s = selectedPacketStart_s;
        result.selectedPacketEnd_s = selectedPacketEnd_s;

        result.downstreamWindowStart_s = downstreamWindowStart_s;
        result.downstreamWindowEnd_s = downstreamWindowEnd_s;

        result.rawWaveformStored = false;

        result.status = stage1Status;
        result.message = stage1Message;

        resultFile = fullfile( ...
            captureFolder,"Stage1PacketResults.mat");

        save(resultFile,"result","cfg","expectedPacket","-v7.3");

        resultFiles(c) = resultFile;

        %% =================================================================
        % PART F: DIAGNOSTIC FIGURES
        % =================================================================

        plotStride = max(1,ceil(numel(t)/cfg.MAX_PLOT_POINTS));
        plotIdx = 1:plotStride:numel(t);

        vis = onOff(cfg.SHOW_FIGURES);

        % FIGURE 1
        fig1 = figure('Visible',vis,'Color','w', ...
            'Position',[80 80 1500 900]);

        tl = tiledlayout(fig1,3,1, ...
            'TileSpacing','compact','Padding','compact');

        title(tl,sprintf( ...
            "Capture %03d | Attempt %.0f | %.3g mA | command decode", ...
            captureID,attemptNumber,commandCurrent_mA));

        ax1 = nexttile(tl);
        plot(ax1,t(plotIdx)*1e3,d5V(plotIdx),'LineWidth',0.7);
        hold(ax1,'on');
        yline(ax1,d5Threshold,':','HandleVisibility','off');
        grid(ax1,'on');
        ylabel(ax1,'D5 (V)');
        hold(ax1,'off');

        ax2 = nexttile(tl);
        plot(ax2,t(plotIdx)*1e3,d8V(plotIdx),'LineWidth',0.7);
        hold(ax2,'on');
        yline(ax2,d8Threshold,':','HandleVisibility','off');
        grid(ax2,'on');
        ylabel(ax2,'D8 (V)');
        hold(ax2,'off');

        ax3 = nexttile(tl);
        stairs(ax3,t(plotIdx)*1e3,double(cleanCode(plotIdx)), ...
            'LineWidth',0.9);
        grid(ax3,'on');
        ylim(ax3,[-0.3 3.4]);
        yticks(ax3,[0 1 2 3]);
        yticklabels(ax3,{'00','01','10','11'});
        ylabel(ax3,'D8D5');
        xlabel(ax3,'Time (ms)');

        linkaxes([ax1 ax2 ax3],'x');

        % FIGURE 2
        fig2 = figure('Visible',vis,'Color','w', ...
            'Position',[100 100 1500 700]);

        ax = axes(fig2);

        plot(ax,t(plotIdx)*1e3,currentRaw_mA(plotIdx),'LineWidth',0.7);
        hold(ax,'on');

        for p = 1:height(packetTable)

            if packetTable.IsSelected(p)
                ls = '-';
                lw = 2.2;
                label = sprintf("SELECTED complete P%d",p);
            elseif packetTable.IsComplete(p)
                ls = '-';
                lw = 1.2;
                label = sprintf("Complete P%d",p);
            else
                ls = '--';
                lw = 1.0;
                label = sprintf("Incomplete P%d",p);
            end

            xline(ax,packetTable.StartTime_s(p)*1e3,ls,label, ...
                'LineWidth',lw,'HandleVisibility','off');

            if isfinite(packetTable.EndTime_s(p))
                xline(ax,packetTable.EndTime_s(p)*1e3,ls, ...
                    'LineWidth',lw,'HandleVisibility','off');
            end
        end

        grid(ax,'on');
        xlabel(ax,'Time (ms)');
        ylabel(ax,'Measured current (mA)');
        title(ax,sprintf( ...
            "Capture %03d | complete=%d | partial=%d | %s", ...
            captureID,nCompletePackets,partialFragmentCount,stage1Status));
        hold(ax,'off');

        % FIGURE 3
        fig3 = [];

        if ~isempty(selectedCommandTable)

            fig3 = figure('Visible',vis,'Color','w', ...
                'Position',[120 120 1500 850]);

            tl3 = tiledlayout(fig3,2,1, ...
                'TileSpacing','compact','Padding','compact');

            title(tl3,sprintf( ...
                "Capture %03d | selected complete packet",captureID));

            ax31 = nexttile(tl3);

            commandY = arrayfun( ...
                @transitionClassNumber, ...
                selectedCommandTable.TransitionClass);

            stem(ax31,selectedCommandTable.CommandTime_ms, ...
                commandY,'filled','MarkerSize',3);

            grid(ax31,'on');
            ylim(ax31,[0.4 4.6]);
            yticks(ax31,[1 2 3 4]);
            yticklabels(ax31,{ ...
                '0 -> +I','+I -> -I','-I -> +I','-I -> 0'});
            ylabel(ax31,'Command');

            ax32 = nexttile(tl3);

            m = t>=downstreamWindowStart_s & t<=downstreamWindowEnd_s;
            idx = find(m);
            ds = max(1,ceil(numel(idx)/cfg.MAX_PLOT_POINTS));
            idx = idx(1:ds:end);

            plot(ax32,t(idx)*1e3,currentRaw_mA(idx),'LineWidth',0.7);
            hold(ax32,'on');

            for e = 1:height(selectedCommandTable)
                xline(ax32,selectedCommandTable.CommandTime_ms(e),':', ...
                    'HandleVisibility','off');
            end

            grid(ax32,'on');
            xlabel(ax32,'Time (ms)');
            ylabel(ax32,'Measured current (mA)');
            title(ax32,'CH3 with selected packet command times');
            hold(ax32,'off');

            linkaxes([ax31 ax32],'x');
        end

        if cfg.SAVE_PLOTS

            exportStage1Figure(fig1, ...
                fullfile(captureFolder,"01_CommandDetection.png"), ...
                cfg.FIGURE_RESOLUTION_DPI);

            exportStage1Figure(fig2, ...
                fullfile(captureFolder,"02_PacketOverview.png"), ...
                cfg.FIGURE_RESOLUTION_DPI);

            if ~isempty(fig3)
                exportStage1Figure(fig3, ...
                    fullfile(captureFolder, ...
                    "03_SelectedPacketCommandsAndCH3.png"), ...
                    cfg.FIGURE_RESOLUTION_DPI);
            end
        end

        if ~cfg.SHOW_FIGURES
            close(fig1);
            close(fig2);
            if ~isempty(fig3), close(fig3); end
        end

        %% =================================================================
        % PART G: MASTER TABLE PARTS
        % =================================================================

        selectedCount = height(selectedCommandTable);

        if isempty(selectedCommandTable)

            nZeroToPos = 0;
            nPosToNeg = 0;
            nNegToPos = 0;
            nNegToZero = 0;
            nUnexpected = 0;

        else

            cls = selectedCommandTable.TransitionClass;

            nZeroToPos = nnz(cls=="zero_to_pos");
            nPosToNeg = nnz(cls=="pos_to_neg");
            nNegToPos = nnz(cls=="neg_to_pos");
            nNegToZero = nnz(cls=="neg_to_zero");
            nUnexpected = nnz(cls=="unexpected");
        end

        captureSummaryParts{c} = table( ...
            captureID,attemptNumber,commandCurrent_mA, ...
            captureWithinAttempt,fileName,string(csvPath), ...
            Fs/1e6,(t(end)-t(1))*1e3,nCommands, ...
            nPacketCandidates,nCompletePackets,partialFragmentCount, ...
            selectedPacketCandidate, ...
            selectedPacketStart_s*1e3,selectedPacketEnd_s*1e3, ...
            selectedPacketDuration_ms,selectedPacketMidpoint_ms, ...
            selectedCount,nZeroToPos,nPosToNeg,nNegToPos,nNegToZero, ...
            nUnexpected,stage1Status,stage1Message, ...
            'VariableNames',{ ...
            'CaptureID','AttemptNumber','CommandCurrent_mA', ...
            'CaptureWithinAttempt','FileName','FullPath', ...
            'Fs_MSa_s','Duration_ms','DecodedCommandEvents', ...
            'PacketCandidates','CompletePacketsFound', ...
            'PartialFragmentsFound','SelectedPacketCandidate', ...
            'SelectedPacketStart_ms','SelectedPacketEnd_ms', ...
            'SelectedPacketDuration_ms','SelectedPacketMidpoint_ms', ...
            'SelectedCommandEvents','ZeroToPosCount','PosToNegCount', ...
            'NegToPosCount','NegToZeroCount','UnexpectedCount', ...
            'Stage1Status','Stage1Message'});

        if ~isempty(selectedCommandTable)
            selectedEventParts{c} = selectedCommandTable;
        end

        if ~isempty(packetCsvTable)
            packetCandidateParts{c} = packetCsvTable;
        end

        fprintf("\nCAPTURE RESULT\n");
        fprintf("Status                     : %s\n",stage1Status);
        fprintf("Selected packet            : %.0f\n",selectedPacketCandidate);
        fprintf("Selected commands          : %d\n",selectedCount);
        fprintf("Message                    : %s\n",stage1Message);

        clear data t d5V d8V outputV currentRaw_mA ...
            d5Bit d8Bit rawCode cleanCode

    catch ME

        fprintf(2,"\nCAPTURE FAILED\n");
        fprintf(2,"Capture ID : %d\n",captureID);
        fprintf(2,"Reason     : %s\n",ME.message);

        captureSummaryParts{c} = failureSummary( ...
            captureID,attemptNumber,commandCurrent_mA, ...
            captureWithinAttempt,fileName,csvPath,ME.message);
    end
end

%% ========================================================================
% MASTER OUTPUTS
% ========================================================================

captureSummaryParts = ...
    captureSummaryParts(~cellfun(@isempty,captureSummaryParts));

if isempty(captureSummaryParts)
    CaptureSummary = table();
else
    CaptureSummary = vertcat(captureSummaryParts{:});
end

selectedEventParts = ...
    selectedEventParts(~cellfun(@isempty,selectedEventParts));

if isempty(selectedEventParts)
    SelectedCommandEvents = table();
else
    SelectedCommandEvents = vertcat(selectedEventParts{:});
end

packetCandidateParts = ...
    packetCandidateParts(~cellfun(@isempty,packetCandidateParts));

if isempty(packetCandidateParts)
    PacketCandidates = table();
else
    PacketCandidates = vertcat(packetCandidateParts{:});
end

save( ...
    fullfile(cfg.STAGE1_OUTPUT_FOLDER,"Stage1MasterResults.mat"), ...
    "CaptureSummary","SelectedCommandEvents","PacketCandidates", ...
    "resultFiles","expectedPacket","cfg","-v7.3");

if ~isempty(CaptureSummary)
    writetable(CaptureSummary, ...
        fullfile(cfg.STAGE1_OUTPUT_FOLDER,"Stage1CaptureSummary.csv"));
end

if ~isempty(SelectedCommandEvents)
    writetable(SelectedCommandEvents, ...
        fullfile(cfg.STAGE1_OUTPUT_FOLDER, ...
        "Stage1SelectedCommandEvents.csv"));
end

if ~isempty(PacketCandidates)
    writetable(PacketCandidates, ...
        fullfile(cfg.STAGE1_OUTPUT_FOLDER, ...
        "Stage1PacketCandidates.csv"));
end

%% ========================================================================
% FINAL SUMMARY
% ========================================================================

fprintf("\n============================================================\n");
fprintf("STAGE 1 COMPLETE\n");
fprintf("============================================================\n");

if ~isempty(CaptureSummary)

    fprintf("Captures processed          : %d\n",height(CaptureSummary));
    fprintf("PASS                        : %d\n", ...
        nnz(CaptureSummary.Stage1Status=="PASS"));
    fprintf("WARNING                     : %d\n", ...
        nnz(CaptureSummary.Stage1Status=="WARNING"));
    fprintf("FAIL                        : %d\n", ...
        nnz(CaptureSummary.Stage1Status=="FAIL"));
    fprintf("Selected complete commands  : %d\n", ...
        height(SelectedCommandEvents));
end

fprintf("\nExpected if all 30 captures pass: 30 x 41 = 1230 events\n");
fprintf("\nDownstream rule:\n");
fprintf("Use ONLY Stage1SelectedCommandEvents or result.selectedCommandTable.\n");
fprintf("Incomplete edge packets are diagnostic only.\n");

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function expected = buildExpectedPacket(P)

    N = 2*P+1;

    transitionClass = strings(N,1);
    pulseNumber = zeros(N,1);

    i = 1;

    transitionClass(i) = "zero_to_pos";
    pulseNumber(i) = 1;
    i = i+1;

    for p = 1:P

        transitionClass(i) = "pos_to_neg";
        pulseNumber(i) = p;
        i = i+1;

        if p<P
            transitionClass(i) = "neg_to_pos";
            pulseNumber(i) = p+1;
            i = i+1;
        end
    end

    transitionClass(i) = "neg_to_zero";
    pulseNumber(i) = P;

    eventNumberWithinPacket = (1:N).';

    expected = table( ...
        eventNumberWithinPacket,pulseNumber,transitionClass, ...
        'VariableNames',{ ...
        'EventNumberWithinPacket','PulseNumber','TransitionClass'});
end

function packets = identifySemanticPackets(commandTable,expectedPacket)

    classes = string(commandTable.TransitionClass);

    startRows = find(classes=="zero_to_pos");

    if isempty(startRows)
        packets = emptyPacketTable();
        return;
    end

    rows = cell(numel(startRows),14);

    for s = 1:numel(startRows)

        startRow = startRows(s);

        if s<numel(startRows)
            searchEnd = startRows(s+1)-1;
        else
            searchEnd = height(commandTable);
        end

        searchRows = startRow:searchEnd;

        relEnd = find( ...
            classes(searchRows)=="neg_to_zero",1,'first');

        if isempty(relEnd)

            endRow = NaN;
            packetClasses = classes(searchRows);
            endTime_s = NaN;
            msg = "Incomplete: start found but no -I->0 before next start/capture end";

        else

            endRow = searchRows(relEnd);
            packetClasses = classes(startRow:endRow);
            endTime_s = commandTable.CommandTime_s(endRow);
            msg = "";
        end

        eventCount = numel(packetClasses);

        c01 = nnz(packetClasses=="zero_to_pos");
        cPN = nnz(packetClasses=="pos_to_neg");
        cNP = nnz(packetClasses=="neg_to_pos");
        cN0 = nnz(packetClasses=="neg_to_zero");
        cU  = nnz(packetClasses=="unexpected");

        correctLength = eventCount==height(expectedPacket);

        correctCounts = ...
            c01==1 && ...
            cPN==nnz(expectedPacket.TransitionClass=="pos_to_neg") && ...
            cNP==nnz(expectedPacket.TransitionClass=="neg_to_pos") && ...
            cN0==1 && ...
            cU==0;

        if correctLength
            correctOrder = all( ...
                packetClasses(:)==expectedPacket.TransitionClass(:));
        else
            correctOrder = false;
        end

        hasEnd = isfinite(endRow);

        complete = ...
            hasEnd && correctLength && correctCounts && correctOrder;

        if complete
            msg = "Complete: exact expected semantic sequence";
        elseif hasEnd && strlength(msg)==0
            msg = sprintf( ...
                "Incomplete/malformed: start/end present but N=%d or sequence mismatch", ...
                eventCount);
        end

        startTime_s = commandTable.CommandTime_s(startRow);

        if isfinite(endTime_s)
            midTime_s = 0.5*(startTime_s+endTime_s);
        else
            midTime_s = NaN;
        end

        rows(s,:) = { ...
            s,startRow,endRow,startTime_s,endTime_s,midTime_s, ...
            eventCount,c01,cPN,cNP,cN0,cU,complete,string(msg)};
    end

    packets = cell2table(rows, ...
        'VariableNames',{ ...
        'PacketCandidate','StartGlobalEvent','EndGlobalEvent', ...
        'StartTime_s','EndTime_s','MidTime_s','EventCount', ...
        'ZeroToPosCount','PosToNegCount','NegToPosCount', ...
        'NegToZeroCount','UnexpectedCount','IsComplete', ...
        'ValidationMessage'});

    packets.IsSelected = false(height(packets),1);
end

function T = emptyPacketTable()

    T = table( ...
        zeros(0,1),zeros(0,1),zeros(0,1), ...
        zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
        zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
        false(0,1),strings(0,1),false(0,1), ...
        'VariableNames',{ ...
        'PacketCandidate','StartGlobalEvent','EndGlobalEvent', ...
        'StartTime_s','EndTime_s','MidTime_s','EventCount', ...
        'ZeroToPosCount','PosToNegCount','NegToPosCount', ...
        'NegToZeroCount','UnexpectedCount','IsComplete', ...
        'ValidationMessage','IsSelected'});
end

function T = addPacketMetadata(T,captureID,attempt,current,captureWithin)

    n = height(T);

    T.CaptureID = repmat(captureID,n,1);
    T.AttemptNumber = repmat(attempt,n,1);
    T.CommandCurrent_mA = repmat(current,n,1);
    T.CaptureWithinAttempt = repmat(captureWithin,n,1);

    T = movevars(T, ...
        {'CaptureID','AttemptNumber','CommandCurrent_mA', ...
        'CaptureWithinAttempt'},'Before',1);
end

function [data,t,t0,Ts,header] = loadRigolMemoryCSV(path)

    fid = fopen(path,'r');

    if fid<0
        error("Could not open CSV.");
    end

    cleanup = onCleanup(@() fclose(fid));

    header = fgetl(fid);

    tok = regexp(header, ...
        't0\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
        'tokens','once');

    if isempty(tok), error("Could not parse t0."); end
    t0 = str2double(tok{1});

    tok = regexp(header, ...
        'tInc\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)', ...
        'tokens','once');

    if isempty(tok), error("Could not parse tInc."); end
    Ts = str2double(tok{1});

    data = readmatrix(path,'NumHeaderLines',1);

    data(:,all(~isfinite(data),1)) = [];
    data = data(any(isfinite(data),2),:);

    t = t0 + (0:size(data,1)-1).'*Ts;
end

function [bit,threshold] = thresholdBit(v,userThreshold)

    lo = percentileLocal(v,5);
    hi = percentileLocal(v,95);

    if isnan(userThreshold)
        threshold = 0.5*(lo+hi);
    else
        threshold = userThreshold;
    end

    bit = double(v>threshold);
end

function [class,context] = classifyLegacyCodePair(fromCode,toCode)

    fromCode = double(fromCode);
    toCode = double(toCode);

    if fromCode==0 && toCode==2
        class = "zero_to_pos";
        context = "legacy_00_to_10";

    elseif fromCode==2 && toCode==3
        class = "pos_to_neg";
        context = "legacy_first_pos_to_neg";

    elseif fromCode==3 && toCode==1
        class = "neg_to_pos";
        context = "legacy_neg_to_pos";

    elseif fromCode==1 && toCode==3
        class = "pos_to_neg";
        context = "legacy_repeated_pos_to_neg";

    elseif fromCode==3 && toCode==0
        class = "neg_to_zero";
        context = "legacy_neg_to_zero";

    else
        class = "unexpected";
        context = sprintf("legacy_%d_to_%d",fromCode,toCode);
    end
end

function label = transitionCodeLabel(code)

    switch double(code)
        case 0, label = "neg_to_zero";
        case 1, label = "zero_to_pos";
        case 2, label = "neg_to_pos";
        case 3, label = "pos_to_neg";
        otherwise, label = "unexpected";
    end
end

function cleaned = removeShortRuns(code,minSamples)

    cleaned = code(:);

    for iter = 1:30

        [starts,ends,codes] = runsFromCode(cleaned);

        lengths = ends-starts+1;

        shortRuns = find(lengths<minSamples);

        shortRuns(shortRuns==1 | shortRuns==numel(codes)) = [];

        if isempty(shortRuns), break; end

        for jj = 1:numel(shortRuns)

            r = shortRuns(jj);

            cleaned(starts(r):ends(r)) = codes(r-1);
        end
    end
end

function [starts,ends,codes] = runsFromCode(code)

    code = code(:);

    change = [true; diff(double(code))~=0; true];

    edges = find(change);

    starts = edges(1:end-1);
    ends = edges(2:end)-1;
    codes = code(starts);
end

function q = percentileLocal(x,p)

    x = sort(x(isfinite(x)));

    if isempty(x)
        q = NaN;
        return;
    end

    if isscalar(x)
        q = x;
        return;
    end

    r = 1 + (p/100)*(numel(x)-1);

    lo = floor(r);
    hi = ceil(r);

    if lo==hi
        q = x(lo);
    else
        q = x(lo)+(r-lo)*(x(hi)-x(lo));
    end
end

function n = transitionClassNumber(type)

    switch string(type)
        case "zero_to_pos", n = 1;
        case "pos_to_neg", n = 2;
        case "neg_to_pos", n = 3;
        case "neg_to_zero", n = 4;
        otherwise, n = NaN;
    end
end

function value = getNumericMeta(meta,names,defaultValue)

    value = defaultValue;

    for k = 1:numel(names)

        name = char(names(k));

        if isfield(meta,name)

            x = meta.(name);

            if isnumeric(x) && ~isempty(x)
                value = double(x(1));
                return;
            end

            if isstring(x) || ischar(x)
                y = str2double(string(x));
                if isfinite(y)
                    value = y;
                    return;
                end
            end
        end
    end
end

function value = getStringMeta(meta,names,defaultValue)

    value = string(defaultValue);

    for k = 1:numel(names)

        name = char(names(k));

        if isfield(meta,name)

            x = meta.(name);

            if isstring(x) || ischar(x)
                value = string(x);
                return;
            end
        end
    end
end

function exportStage1Figure(fig,filePath,resolution)

    drawnow;

    try
        exportgraphics(fig,filePath, ...
            'Resolution',resolution,'BackgroundColor','white');
    catch
        saveas(fig,filePath);
    end
end

function T = failureSummary( ...
    captureID,attempt,current,captureWithin,fileName,csvPath,message)

    T = table( ...
        captureID,attempt,current,captureWithin,fileName,string(csvPath), ...
        NaN,NaN,NaN,0,0,0,NaN,NaN,NaN,NaN,NaN, ...
        0,0,0,0,0,0,"FAIL",string(message), ...
        'VariableNames',{ ...
        'CaptureID','AttemptNumber','CommandCurrent_mA', ...
        'CaptureWithinAttempt','FileName','FullPath', ...
        'Fs_MSa_s','Duration_ms','DecodedCommandEvents', ...
        'PacketCandidates','CompletePacketsFound', ...
        'PartialFragmentsFound','SelectedPacketCandidate', ...
        'SelectedPacketStart_ms','SelectedPacketEnd_ms', ...
        'SelectedPacketDuration_ms','SelectedPacketMidpoint_ms', ...
        'SelectedCommandEvents','ZeroToPosCount','PosToNegCount', ...
        'NegToPosCount','NegToZeroCount','UnexpectedCount', ...
        'Stage1Status','Stage1Message'});
end

function s = onOff(tf)
    if tf, s='on'; else, s='off'; end
end

function s = yesNo(tf)
    if tf, s="YES"; else, s="NO"; end
end
