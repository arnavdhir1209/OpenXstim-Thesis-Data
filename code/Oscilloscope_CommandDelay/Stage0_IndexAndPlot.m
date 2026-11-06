%% ============================================================
%  OPENXSTIM STAGE 0
%  MULTI-CAPTURE DISCOVERY, IMPORT AND RAW-DATA OVERVIEW
%
%  Purpose:
%    1. Find Attempts 6 to 11 automatically.
%    2. Find every CSV directly inside each attempt folder.
%    3. Read the RIGOL timing metadata.
%    4. Record sample rate, point count, duration, etc.
%    5. Build a reusable capture index.
%    6. Create decimated raw-data previews for plotting.
%    7. Save a manifest for later batch classification.
%
%  IMPORTANT:
%    Full raw waveforms are NOT all kept in RAM simultaneously.
%    Each CSV is loaded once, preview data is retained, then the
%    full array is cleared.
%
%  Channel convention:
%    CH1 = D5
%    CH2 = D8
%    CH3 = measured output
%
% ============================================================

clear;
clc;
close all;

%% ============================================================
% USER SETTINGS
% ============================================================

VALID_ATTEMPTS = 6:11;

% Current bench load.
% CH3 voltage is converted to current using:
%
%       I_mA = V / R * 1000
%
LOAD_OHMS = 1000;

% Maximum points retained PER CAPTURE for overview plotting.
% This does NOT affect the original CSV or later classification.
MAX_PLOT_POINTS = 40000;

SAVE_PLOTS = true;
SHOW_FIGURES = true;

PLOT_RESOLUTION_DPI = 180;


%% ============================================================
% FIND FOLDER STRUCTURE
% ============================================================

scriptPath = mfilename('fullpath');

if isempty(scriptPath)
    analysisDir = pwd;
else
    analysisDir = fileparts(scriptPath);
end

dataRoot = fileparts(analysisDir);

outputDir = fullfile(analysisDir, 'Stage0_CaptureIndex');

if ~exist(outputDir, 'dir')
    mkdir(outputDir);
end

fprintf('\n');
fprintf('============================================================\n');
fprintf('OPENXSTIM STAGE 0: MULTI-CAPTURE IMPORT\n');
fprintf('============================================================\n');
fprintf('Analysis folder : %s\n', analysisDir);
fprintf('Data root       : %s\n', dataRoot);
fprintf('Output folder   : %s\n', outputDir);


%% ============================================================
% FIND VALID ATTEMPT FOLDERS
% ============================================================

dirInfo = dir(dataRoot);

attemptFolders = struct([]);
nAttemptFolders = 0;

fprintf('\nSearching for valid current-sweep attempt folders...\n\n');

for k = 1:numel(dirInfo)

    if ~dirInfo(k).isdir
        continue;
    end

    folderName = dirInfo(k).name;

    % Match folder format:
    %
    %   Attempt 6 5mA
    %   Attempt 7 10mA
    %   Attempt 8 15mA
    %   ...
    %
    % Also tolerates trailing spaces.

    token = regexpi( ...
        folderName, ...
        '^Attempt\s+(\d+)\s+(\d+(?:\.\d+)?)mA\s*$', ...
        'tokens', ...
        'once');

    if isempty(token)
        continue;
    end

    % Extract information directly from folder name
    attemptNumber = str2double(token{1});
    commandCurrent_mA = str2double(token{2});

    % Only keep Attempts 6 through 11
    if attemptNumber < 6 || attemptNumber > 11
        continue;
    end

    nAttemptFolders = nAttemptFolders + 1;

    attemptFolders(nAttemptFolders).attemptNumber = attemptNumber;
    attemptFolders(nAttemptFolders).commandCurrent_mA = commandCurrent_mA;
    attemptFolders(nAttemptFolders).folderName = string(folderName);
    attemptFolders(nAttemptFolders).folderPath = ...
        string(fullfile(dataRoot, folderName));

end


%% ============================================================
% CHECK RESULTS
% ============================================================

if isempty(attemptFolders)
    error('No valid Attempt 6 to 11 current folders were found.');
end

% Sort by commanded current
[~, order] = sort([attemptFolders.commandCurrent_mA]);
attemptFolders = attemptFolders(order);

fprintf('Detected current-sweep folders:\n');

for k = 1:numel(attemptFolders)

    fprintf( ...
        '  Attempt %2d   %5.1f mA   %s\n', ...
        attemptFolders(k).attemptNumber, ...
        attemptFolders(k).commandCurrent_mA, ...
        attemptFolders(k).folderName);

end

fprintf('\nTotal valid current folders: %d\n', numel(attemptFolders));


%% ============================================================
% IMPORT EVERY CSV
% ============================================================

captureIndex = struct([]);
manifestRows = struct([]);

captureCounter = 0;

fprintf('\n');
fprintf('============================================================\n');
fprintf('IMPORTING CAPTURES\n');
fprintf('============================================================\n');


for a = 1:numel(attemptFolders)

    attemptNumber = attemptFolders(a).attemptNumber;
    attemptPath   = char(attemptFolders(a).folderPath);
    current_mA    = attemptFolders(a).commandCurrent_mA;

    csvFiles = dir(fullfile(attemptPath, '*.csv'));

    if isempty(csvFiles)

        fprintf( ...
            '\nWARNING: Attempt %d contains no CSV files.\n', ...
            attemptNumber);

        continue;
    end

    % Stable alphabetical ordering within each attempt.
    [~, fileOrder] = sort(lower(string({csvFiles.name})));

    csvFiles = csvFiles(fileOrder);

    fprintf('\n');
    fprintf('Attempt %d, %.3g mA\n', attemptNumber, current_mA);
    fprintf('Found %d CSV files\n', numel(csvFiles));


    for f = 1:numel(csvFiles)

        captureCounter = captureCounter + 1;

        fileName = csvFiles(f).name;
        filePath = fullfile(attemptPath, fileName);

        fprintf('\n');
        fprintf('Capture %d\n', captureCounter);
        fprintf('  File: %s\n', fileName);

        try

            %% ------------------------------------------------
            % Read header
            % -------------------------------------------------

            fid = fopen(filePath, 'r');

            if fid == -1
                error('Could not open file.');
            end

            headerLine = fgetl(fid);
            fclose(fid);

            if ~ischar(headerLine)
                error('Could not read RIGOL header.');
            end


            %% ------------------------------------------------
            % Parse timing metadata
            % -------------------------------------------------

            t0Token = regexp( ...
                headerLine, ...
                't0\s*=\s*([+\-]?\d*\.?\d+(?:[eE][+\-]?\d+)?)', ...
                'tokens', ...
                'once');

            tIncToken = regexp( ...
                headerLine, ...
                'tInc\s*=\s*([+\-]?\d*\.?\d+(?:[eE][+\-]?\d+)?)', ...
                'tokens', ...
                'once');


            if isempty(t0Token)
                error('Could not find t0 in header.');
            end

            if isempty(tIncToken)
                error('Could not find tInc in header.');
            end


            t0_s   = str2double(t0Token{1});
            tInc_s = str2double(tIncToken{1});

            Fs_Hz = 1 / tInc_s;


            %% ------------------------------------------------
            % Read numerical data
            % -------------------------------------------------

            raw = readmatrix( ...
                filePath, ...
                'NumHeaderLines', 1);


            % Remove completely empty rows.
            raw = raw(~all(isnan(raw), 2), :);


            if size(raw, 2) < 3
                error( ...
                    'Expected at least 3 data columns, found %d.', ...
                    size(raw, 2));
            end


            % We currently only require CH1, CH2 and CH3.
            raw = raw(:, 1:3);

            nSamples = size(raw, 1);

            captureDuration_s = ...
                (nSamples - 1) * tInc_s;


            %% ------------------------------------------------
            % Create plotting preview
            % -------------------------------------------------

            plotStride = max( ...
                1, ...
                ceil(nSamples / MAX_PLOT_POINTS));

            plotIdx = (1:plotStride:nSamples).';

            previewTime_s = ...
                t0_s + (plotIdx - 1) * tInc_s;


            previewD5_V = raw(plotIdx, 1);
            previewD8_V = raw(plotIdx, 2);
            previewCH3_V = raw(plotIdx, 3);


            % For current 1 kohm resistor experiments.
            previewCurrent_mA = ...
                previewCH3_V / LOAD_OHMS * 1000;


            %% ------------------------------------------------
            % Store reusable capture index entry
            % -------------------------------------------------

            captureIndex(captureCounter).captureID = captureCounter;

            captureIndex(captureCounter).attemptNumber = ...
                attemptNumber;

            captureIndex(captureCounter).commandCurrent_mA = ...
                current_mA;

            captureIndex(captureCounter).captureWithinAttempt = ...
                f;

            captureIndex(captureCounter).attemptFolder = ...
                string(attemptFolders(a).folderName);

            captureIndex(captureCounter).fileName = ...
                string(fileName);

            captureIndex(captureCounter).filePath = ...
                string(filePath);

            captureIndex(captureCounter).fileSize_MB = ...
                csvFiles(f).bytes / 1024^2;


            % Timing metadata.
            captureIndex(captureCounter).t0_s = t0_s;
            captureIndex(captureCounter).tInc_s = tInc_s;
            captureIndex(captureCounter).Fs_Hz = Fs_Hz;
            captureIndex(captureCounter).nSamples = nSamples;
            captureIndex(captureCounter).duration_s = ...
                captureDuration_s;


            % Channel mapping.
            captureIndex(captureCounter).channelMap.CH1 = "D5";
            captureIndex(captureCounter).channelMap.CH2 = "D8";
            captureIndex(captureCounter).channelMap.CH3 = ...
                "Measured output";


            % Decimated preview only.
            captureIndex(captureCounter).preview.time_s = ...
                previewTime_s;

            captureIndex(captureCounter).preview.time_ms = ...
                previewTime_s * 1e3;

            captureIndex(captureCounter).preview.D5_V = ...
                previewD5_V;

            captureIndex(captureCounter).preview.D8_V = ...
                previewD8_V;

            captureIndex(captureCounter).preview.CH3_V = ...
                previewCH3_V;

            captureIndex(captureCounter).preview.current_mA = ...
                previewCurrent_mA;

            captureIndex(captureCounter).preview.plotStride = ...
                plotStride;


            %% ------------------------------------------------
            % Manifest row
            % -------------------------------------------------

            manifestRows(captureCounter).CaptureID = ...
                captureCounter;

            manifestRows(captureCounter).Attempt = ...
                attemptNumber;

            manifestRows(captureCounter).CommandCurrent_mA = ...
                current_mA;

            manifestRows(captureCounter).CaptureWithinAttempt = ...
                f;

            manifestRows(captureCounter).FileName = ...
                string(fileName);

            manifestRows(captureCounter).FullPath = ...
                string(filePath);

            manifestRows(captureCounter).FileSize_MB = ...
                csvFiles(f).bytes / 1024^2;

            manifestRows(captureCounter).Samples = ...
                nSamples;

            manifestRows(captureCounter).t0_s = ...
                t0_s;

            manifestRows(captureCounter).tInc_s = ...
                tInc_s;

            manifestRows(captureCounter).Fs_MSa_s = ...
                Fs_Hz / 1e6;

            manifestRows(captureCounter).Duration_ms = ...
                captureDuration_s * 1e3;

            manifestRows(captureCounter).PreviewStride = ...
                plotStride;

            manifestRows(captureCounter).ImportStatus = ...
                "PASS";

            manifestRows(captureCounter).ImportMessage = ...
                "";


            fprintf( ...
                '  Samples : %d\n', ...
                nSamples);

            fprintf( ...
                '  Fs      : %.6f MSa/s\n', ...
                Fs_Hz / 1e6);

            fprintf( ...
                '  Duration: %.6f ms\n', ...
                captureDuration_s * 1e3);

            fprintf( ...
                '  Preview : every %d samples\n', ...
                plotStride);


            % Full waveform no longer needed in memory.
            clear raw;


        catch ME

            fprintf( ...
                '  IMPORT FAILED: %s\n', ...
                ME.message);


            captureIndex(captureCounter).captureID = ...
                captureCounter;

            captureIndex(captureCounter).attemptNumber = ...
                attemptNumber;

            captureIndex(captureCounter).commandCurrent_mA = ...
                current_mA;

            captureIndex(captureCounter).captureWithinAttempt = ...
                f;

            captureIndex(captureCounter).fileName = ...
                string(fileName);

            captureIndex(captureCounter).filePath = ...
                string(filePath);

            captureIndex(captureCounter).importFailed = true;

            captureIndex(captureCounter).importMessage = ...
                string(ME.message);


            manifestRows(captureCounter).CaptureID = ...
                captureCounter;

            manifestRows(captureCounter).Attempt = ...
                attemptNumber;

            manifestRows(captureCounter).CommandCurrent_mA = ...
                current_mA;

            manifestRows(captureCounter).CaptureWithinAttempt = ...
                f;

            manifestRows(captureCounter).FileName = ...
                string(fileName);

            manifestRows(captureCounter).FullPath = ...
                string(filePath);

            manifestRows(captureCounter).FileSize_MB = ...
                csvFiles(f).bytes / 1024^2;

            manifestRows(captureCounter).Samples = NaN;
            manifestRows(captureCounter).t0_s = NaN;
            manifestRows(captureCounter).tInc_s = NaN;
            manifestRows(captureCounter).Fs_MSa_s = NaN;
            manifestRows(captureCounter).Duration_ms = NaN;
            manifestRows(captureCounter).PreviewStride = NaN;

            manifestRows(captureCounter).ImportStatus = ...
                "FAIL";

            manifestRows(captureCounter).ImportMessage = ...
                string(ME.message);

        end

    end

end


%% ============================================================
% BUILD MANIFEST TABLE
% ============================================================

manifest = struct2table(manifestRows);

manifest = sortrows( ...
    manifest, ...
    {'Attempt', 'CaptureWithinAttempt'});


fprintf('\n');
fprintf('============================================================\n');
fprintf('CAPTURE MANIFEST\n');
fprintf('============================================================\n');

disp(manifest(:, { ...
    'CaptureID', ...
    'Attempt', ...
    'CommandCurrent_mA', ...
    'CaptureWithinAttempt', ...
    'Samples', ...
    'Fs_MSa_s', ...
    'Duration_ms', ...
    'ImportStatus'}));


%% ============================================================
% SAVE INDEX BEFORE PLOTTING
% ============================================================

config = struct;

config.validAttempts = VALID_ATTEMPTS;
config.loadOhms = LOAD_OHMS;
config.maxPlotPoints = MAX_PLOT_POINTS;
config.analysisDir = string(analysisDir);
config.dataRoot = string(dataRoot);


save( ...
    fullfile(outputDir, 'CaptureIndex.mat'), ...
    'captureIndex', ...
    'manifest', ...
    'config', ...
    '-v7.3');


writetable( ...
    manifest, ...
    fullfile(outputDir, 'CaptureManifest.csv'));


%% ============================================================
% RAW CAPTURE PLOTS FOR EACH CURRENT
% ============================================================

fprintf('\n');
fprintf('Generating raw-data overview plots...\n');


for a = 1:numel(attemptFolders)

    attemptNumber = attemptFolders(a).attemptNumber;
    current_mA = attemptFolders(a).commandCurrent_mA;

    attemptCaptureIdx = find( ...
        arrayfun( ...
            @(x) ...
            isfield(x, 'attemptNumber') && ...
            x.attemptNumber == attemptNumber && ...
            isfield(x, 'preview'), ...
            captureIndex));


    if isempty(attemptCaptureIdx)
        continue;
    end


    nCap = numel(attemptCaptureIdx);


    if SHOW_FIGURES
        visibility = 'off';
    else
        visibility = 'off';
    end


    fig = figure( ...
        'Name', ...
        sprintf('Attempt %d raw captures', attemptNumber), ...
        'Visible', visibility, ...
        'Position', ...
        [80 80 1800 max(900, 220*nCap)]);


    tl = tiledlayout( ...
        nCap, ...
        3, ...
        'TileSpacing', 'compact', ...
        'Padding', 'compact');


    title( ...
        tl, ...
        sprintf( ...
            'Attempt %d, commanded %.3g mA, raw capture overview', ...
            attemptNumber, ...
            current_mA));


    for j = 1:nCap

        c = captureIndex(attemptCaptureIdx(j));


        %% D5
        ax = nexttile;

        plot( ...
            c.preview.time_ms, ...
            c.preview.D5_V);

        grid on;

        ylabel( ...
            sprintf('Capture %d\nD5 (V)', j));

        if j == 1
            title('CH1 = D5');
        end


        %% D8
        ax = nexttile;

        plot( ...
            c.preview.time_ms, ...
            c.preview.D8_V);

        grid on;

        ylabel('D8 (V)');

        if j == 1
            title('CH2 = D8');
        end


        %% Output
        ax = nexttile;

        plot( ...
            c.preview.time_ms, ...
            c.preview.current_mA);

        grid on;

        ylabel('Current (mA)');

        if j == 1
            title('CH3 = output current');
        end

        text( ...
            0.01, ...
            0.92, ...
            char(c.fileName), ...
            'Units', 'normalized', ...
            'Interpreter', 'none', ...
            'FontSize', 8);


        if j == nCap

            nexttile((j - 1)*3 + 1);
            xlabel('Time (ms)');

            nexttile((j - 1)*3 + 2);
            xlabel('Time (ms)');

            nexttile((j - 1)*3 + 3);
            xlabel('Time (ms)');

        end

    end


    if SAVE_PLOTS

        fileOut = fullfile( ...
            outputDir, ...
            sprintf( ...
                'Attempt_%02d_%gmA_RawOverview.png', ...
                attemptNumber, ...
                current_mA));

        exportgraphics( ...
            fig, ...
            fileOut, ...
            'Resolution', PLOT_RESOLUTION_DPI);

    end

end


%% ============================================================
% OVERLAY REPEATED CAPTURES FOR EACH CURRENT
% ============================================================

if SHOW_FIGURES
    visibility = 'on';
else
    visibility = 'off';
end


fig = figure( ...
    'Name', 'Output-current repeatability across all currents', ...
    'Visible', visibility, ...
    'Position', [100 100 1500 1000]);


nAttempts = numel(attemptFolders);

nCols = 2;
nRows = ceil(nAttempts / nCols);


tl = tiledlayout( ...
    nRows, ...
    nCols, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');


title( ...
    tl, ...
    'Raw CH3 repeatability across commanded currents');


for a = 1:numel(attemptFolders)

    attemptNumber = attemptFolders(a).attemptNumber;
    current_mA = attemptFolders(a).commandCurrent_mA;


    attemptCaptureIdx = find( ...
        arrayfun( ...
            @(x) ...
            isfield(x, 'attemptNumber') && ...
            x.attemptNumber == attemptNumber && ...
            isfield(x, 'preview'), ...
            captureIndex));


    ax = nexttile;
    hold(ax, 'on');


    for j = 1:numel(attemptCaptureIdx)

        c = captureIndex(attemptCaptureIdx(j));

        plot( ...
            ax, ...
            c.preview.time_ms, ...
            c.preview.current_mA, ...
            'DisplayName', ...
            sprintf('Capture %d', j));

    end


    grid(ax, 'on');

    title( ...
        ax, ...
        sprintf( ...
            'Attempt %d, %.3g mA', ...
            attemptNumber, ...
            current_mA));

    xlabel(ax, 'Time (ms)');
    ylabel(ax, 'Measured current (mA)');

    legend( ...
        ax, ...
        'Location', 'best', ...
        'FontSize', 7);

end


if SAVE_PLOTS

    exportgraphics( ...
        fig, ...
        fullfile( ...
            outputDir, ...
            'AllCurrents_CH3_RawRepeatability.png'), ...
        'Resolution', PLOT_RESOLUTION_DPI);

end


%% ============================================================
% SAMPLING / CAPTURE INFORMATION PLOT
% ============================================================

passed = manifest.ImportStatus == "PASS";
manifestPassed = manifest(passed, :);


fig = figure( ...
    'Name', 'Capture acquisition properties', ...
    'Visible', visibility, ...
    'Position', [120 120 1400 800]);


tl = tiledlayout( ...
    3, ...
    1, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');


%% Sample count
nexttile;

scatter( ...
    manifestPassed.CaptureID, ...
    manifestPassed.Samples, ...
    50, ...
    manifestPassed.CommandCurrent_mA, ...
    'filled');

grid on;

ylabel('Samples');
title('Samples per capture');


%% Sample rate
nexttile;

scatter( ...
    manifestPassed.CaptureID, ...
    manifestPassed.Fs_MSa_s, ...
    50, ...
    manifestPassed.CommandCurrent_mA, ...
    'filled');

grid on;

ylabel('Fs (MSa/s)');
title('Sampling rate per capture');


%% Duration
nexttile;

scatter( ...
    manifestPassed.CaptureID, ...
    manifestPassed.Duration_ms, ...
    50, ...
    manifestPassed.CommandCurrent_mA, ...
    'filled');

grid on;

xlabel('Capture ID');
ylabel('Duration (ms)');
title('Capture duration');


if SAVE_PLOTS

    exportgraphics( ...
        fig, ...
        fullfile( ...
            outputDir, ...
            'AcquisitionProperties.png'), ...
        'Resolution', PLOT_RESOLUTION_DPI);

end


%% ============================================================
% FINAL SUMMARY
% ============================================================

fprintf('\n');
fprintf('============================================================\n');
fprintf('STAGE 0 COMPLETE\n');
fprintf('============================================================\n');

fprintf('Total CSV files indexed : %d\n', height(manifest));
fprintf( ...
    'Successful imports      : %d\n', ...
    nnz(manifest.ImportStatus == "PASS"));

fprintf( ...
    'Failed imports          : %d\n', ...
    nnz(manifest.ImportStatus == "FAIL"));


fprintf('\nSaved:\n');
fprintf('  %s\n', fullfile(outputDir, 'CaptureIndex.mat'));
fprintf('  %s\n', fullfile(outputDir, 'CaptureManifest.csv'));

fprintf('\n');
fprintf('The original full-resolution CSVs remain untouched.\n');
fprintf('CaptureIndex.mat contains metadata and decimated previews.\n');
fprintf('Stage 1 should later load each original CSV individually.\n');

fprintf('\nDone.\n');