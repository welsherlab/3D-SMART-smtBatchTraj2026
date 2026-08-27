%{
smtBatchTraj2026

Performance-optimized version of the smt batchtraj code. This combines
batchtraj_tdms_Galvo, trajLoadTDMS_Galvo, trajLoadTDMSCalibrated.

Note: This master file is set to Read-Only to prevent accidental modifications. If
you wanna run it, make your own copy. Everything you need to run the code
is all inside this script.

Please check out the README pdf
%}

close all; clear;clc;
%% Params
masterDataFolderPath = 'FIXME';
localDataFolderPath = 'FIXME';
matlabNotifierID = 'FIXME'; 

% scripSettings - controls script behavior
scriptSettings.createDupFolderIfExist = true;
scriptSettings.useParallelComputing = false;
scriptSettings.numParallelWorkers = 4;
scriptSettings.useLocalTDMSCopy = true; % recommend true for non-lab PC
scriptSettings.moveLocalFoldertoNetwork = true; 
scriptSettings.notifySlack = false; % required matlabNotifierID 
scriptSettings.makeDataCollage = true;
scriptSettings.saveCollagePNG = true; 
scriptSettings.stageTracking = false;

scriptSettings.fileSizeCutoff = 5e6; %bytes
scriptSettings.trajDurationCutoff = 0.2; %s

scriptSettings.calc1dMSD = true;
scriptSettings.trajMatIsTable = false; % otherwise, save as array

% plotSettings - controls plot appearance
plotSettings.lineWidth = 1;
plotSettings.lineColor = 'blue';
plotSettings.fontSize = 14;
plotSettings.background = 'white';
plotSettings.plotGrid = true;
plotSettings.collagePNGResolution = 200;

%% PRE-ANALYSIS SETUP
%{
1. Create folders to save analysis data
2. Get a list of relevant tdms files (TR files with sufficient size only)
%}

% Going into data folder to filter files
cd(masterDataFolderPath);

dataFolder = uigetdir(masterDataFolderPath, 'Select data folder');
cd(dataFolder);

set(groot, 'DefaultFigureWindowStyle', 'normal');

elapsedTimer = tic; % Start timer

% Create Processed Data folder at save location
if scriptSettings.useLocalTDMSCopy
    processedDataFolderPath = localDataFolderPath;
else
    processedDataFolderPath = dataFolder;
end
processedDataFolderName = 'Processed Data';
baseSavePath = fullfile(processedDataFolderPath, processedDataFolderName);
fprintf('Save location: %s.\n', string(baseSavePath));

if ~exist(baseSavePath, 'dir')
    mkdir(baseSavePath); % Make folder if not exist already
end

localTDMSFolder = fullfile(localDataFolderPath, '_TDMS Local Scratch'); % Local folder to store tdms files
if scriptSettings.useLocalTDMSCopy && ~exist(localTDMSFolder, 'dir')
    mkdir(localTDMSFolder);
end

% Filter files in folder to grab only TR files that exceed the fileSizeCutoff
filesInFolder = dir(fullfile(dataFolder, '*.tdms'));
fileNames = string({filesInFolder.name});
fileBytes = [filesInFolder.bytes];
TRfiles_filtered = fileNames(~contains(fileNames, "IM", 'IgnoreCase', true)...
    & fileBytes >= scriptSettings.fileSizeCutoff);

nFiles = numel(TRfiles_filtered); % Number of files to process
trajectoryNames = erase(TRfiles_filtered, '.tdms');
trajFolderNames = strings(nFiles, 1);
processedDataSavePaths = strings(nFiles, 1);
reservedSavePaths = strings(0, 1);

% If a duplicate folder needs to be created, update the name of folder to
% save data in
for i = 1:nFiles
    trajFolderName_orig = trajectoryNames(i);
    trajFolderName = trajFolderName_orig;

    if scriptSettings.createDupFolderIfExist
        folderCopyCount = 1;
        processedDataSavePath = fullfile(baseSavePath, trajFolderName);

        while exist(processedDataSavePath, 'dir') || any(reservedSavePaths == string(processedDataSavePath))
            trajFolderName = sprintf('%s (%d)', trajFolderName_orig, folderCopyCount);
            processedDataSavePath = fullfile(baseSavePath, trajFolderName);
            folderCopyCount = folderCopyCount + 1;
        end
    else
        processedDataSavePath = fullfile(baseSavePath, trajFolderName);
    end

    trajFolderNames(i) = trajFolderName;
    processedDataSavePaths(i) = processedDataSavePath;
    reservedSavePaths(end+1, 1) = string(processedDataSavePath);
end

%% TRAJECTORY ANALYSIS
tracking = repmat(emptyTrackingStruct(), nFiles, 1); % Init tracking struct

% Process trajectory
if scriptSettings.useParallelComputing % For parallel computing
    % Create parallel pool with numParallelWorkers if not initialized
    p = gcp('nocreate');
    if isempty(p)
        parpool('local', scriptSettings.numParallelWorkers);
    elseif p.NumWorkers ~= scriptSettings.numParallelWorkers
        delete(p);
        parpool('local', scriptSettings.numParallelWorkers);
    end

    pctRunOnAll('set(groot, ''DefaultFigureWindowStyle'', ''normal'')');

    parfor i = 1:nFiles
        tracking(i) = processTrajectory(i, TRfiles_filtered(i),...
            trajectoryNames(i), processedDataSavePaths(i), ...
            dataFolder, scriptSettings, plotSettings, localTDMSFolder);
    end
else % For sequential computing
    for i = 1:nFiles
        tracking(i) = processTrajectory(i, TRfiles_filtered(i),...
            trajectoryNames(i), processedDataSavePaths(i), ...
            dataFolder, scriptSettings, plotSettings, localTDMSFolder);
    end
end

%% POST-ANALYSIS CLEANUP AND MISC
%{
1. Delete tdms files that were copied to local folder
2. Save variables
3. Organize stuffs to their designated folders
4. Let user know once everything is done via Slack
%}

% If useLocalTDMSCopy, delete the tdms files in local folder to save space
% on hard drive
if exist(localTDMSFolder, 'dir')
    leftoverTDMS = dir(fullfile(localTDMSFolder, '*.tdms'));
    leftoverIndex = dir(fullfile(localTDMSFolder, '*.tdms_index'));
    for k = 1:numel(leftoverTDMS)
        delete(fullfile(localTDMSFolder, leftoverTDMS(k).name));
    end
    for k = 1:numel(leftoverIndex)
        delete(fullfile(localTDMSFolder, leftoverIndex(k).name));
    end
end

% Save tracking.mat for info about all trajs processed
save(fullfile(baseSavePath, 'tracking.mat'), 'tracking');

% Save collage PNGs & store them in one folder
if scriptSettings.makeDataCollage && scriptSettings.saveCollagePNG
    collageFolderPath = fullfile(baseSavePath, 'Data Collages');
    if ~exist(collageFolderPath, 'dir')
        mkdir(collageFolderPath);
    end
    for i = 1:length(trajFolderNames)
        fileName = trajFolderNames(i) + " collage.png";
        sourcePNG = fullfile(baseSavePath, trajFolderNames(i), fileName);
        if isfile(sourcePNG)
            movefile(sourcePNG, fullfile(collageFolderPath));
        end
    end
end

% If enabled, move processed data from local folder to network
transferStatuses.statuses = 0;
transferStatuses.msgs = string();
if scriptSettings.useLocalTDMSCopy && scriptSettings.moveLocalFoldertoNetwork
    networkProcessedDataFolderPath = fullfile(dataFolder, processedDataFolderName);
    if ~exist(networkProcessedDataFolderPath, 'dir')
        mkdir(networkProcessedDataFolderPath);
    end
    for i = 1:length(trajFolderNames)
        [transferStatuses(i).statuses, transferStatuses(i).msgs] = movefile(fullfile(baseSavePath, trajFolderNames(i)), networkProcessedDataFolderPath);
    end
    if exist(fullfile(baseSavePath, 'Data Collages'), 'dir')
        [transferStatuses(end+1).statuses, transferStatuses(end+1).msgs] = movefile(fullfile(baseSavePath, 'Data Collages'),...
            networkProcessedDataFolderPath);
    end
    [transferStatuses(end+1).statuses, transferStatuses(end+1).msgs] = movefile(fullfile(baseSavePath, 'tracking.mat'),...
        networkProcessedDataFolderPath);

    % Check move statuses
    if sum([transferStatuses.statuses]) ~= size(transferStatuses,2)
        warning('Bumped into error when moving files from local to network.');
    else
        fprintf('All processed data was moved to %s.\n', string(networkProcessedDataFolderPath));
    end
end

% Ring Slack
if scriptSettings.notifySlack
    notifySlackWhenDone(matlabNotifierID);
end

elapsedTime = toc(elapsedTimer)


openvar('tracking')
clearvars -except tracking scriptSettings plotSettings transferStatuses elapsedTime
%% LOCAL FUNCTIONS
function trackingOut = processTrajectory(i, tdmsFileName,...
    trajectoryName, processedDataSavePath, ...
    dataFolder, scriptSettings, plotSettings, localTDMSFolder)
%{
Central data analysis function. Refer to the README for detailed explanation
about what this function does. 
%}
[~, folderName] = fileparts(processedDataSavePath);
fprintf('Folder name: %s\n', folderName);

scriptSettings.activeFeedbackLoopPeriod = 10e-6;%s

% Static constants - THESE SHOULD NOT BE CHANGED
convCONSTANTS.BITSCONVERSION_X =(1/32767*76.249);
convCONSTANTS.BITSCONVERSION_Y =(1/32767*76.403);
convCONSTANTS.BITSCONVERSION_Z =(1/32767*66.342);
convCONSTANTS.BITSCONVERSION_GALVO = 0.04;

% Init
trackingOut = emptyTrackingStruct();
trackingOut.name = trajectoryName;

networkTDMSPath = fullfile(dataFolder, tdmsFileName);

if scriptSettings.useLocalTDMSCopy
    tdmsData = readTDMSLocalCopy(networkTDMSPath, localTDMSFolder);
else
    tdmsData = tdmsread(networkTDMSPath);
    tdmsData = tdmsData{1};
end

nSamples = size(tdmsData, 1);
trajDuration = nSamples * scriptSettings.activeFeedbackLoopPeriod;
trackingOut.timelength = trajDuration;

if trajDuration < scriptSettings.trajDurationCutoff
    fprintf('Skipped %s because duration was shorter than %.2f s\n', ...
        tdmsFileName, scriptSettings.trajDurationCutoff);
    return
end

fprintf('Processing %s.\n', trajectoryName);
plotSettingsLocal = plotSettings;
plotSettingsLocal.title = trajectoryName;
plotSettingsLocal.savePath = processedDataSavePath;

if ~exist(processedDataSavePath, 'dir')
    mkdir(processedDataSavePath);
end

% Convert bits to physical units
intensity = double(tdmsData.("Intensity (Hz)"));

trajPosition = zeros(nSamples, 3);
trajPosition(:,1) = double(tdmsData.("X readout (bits)")) * convCONSTANTS.BITSCONVERSION_X;
trajPosition(:,2) = double(tdmsData.("Y readout (bits)")) * convCONSTANTS.BITSCONVERSION_Y;
trajPosition(:,3) = double(tdmsData.("Z readout (bits)")) * convCONSTANTS.BITSCONVERSION_Z;

if scriptSettings.stageTracking
    x_Galvo = double(tdmsData.("Galvo X Control (bits)")) * convCONSTANTS.BITSCONVERSION_X;
    y_Galvo = double(tdmsData.("Galvo Y Control (bits)")) * convCONSTANTS.BITSCONVERSION_Y;

    % XY Readout calibration
    if max(x_Galvo) > 46 && min(x_Galvo) <= 46
        [~,xGalvo_46] = min(abs(x_Galvo-46));
        xPiezo_46 = trajPosition(xGalvo_46,1);
    else
        xPiezo_46 = 70.4;
    end

    if max(y_Galvo) > 46 && min(y_Galvo) <= 46
        [~,yGalvo_46] = min(abs(y_Galvo-46));
        yPiezo_46 = trajPosition(yGalvo_46,2);
    else
        yPiezo_46 = 68.8;
    end

    idxX = x_Galvo > 46;
    trajPosition(idxX,1) = xPiezo_46 + ...
        (x_Galvo(idxX) - 46) .* ...
        (-0.01408/2 .* (x_Galvo(idxX) + 46) + 1.83);

    idxY = y_Galvo > 46;
    trajPosition(idxY,2) = yPiezo_46 + ...
        (y_Galvo(idxY) - 46) .* ...
        (-0.01354/2 .* (y_Galvo(idxY) + 46) + 1.792);
else
    x_Galvo = double(tdmsData.("Galvo X Control (bits)")) * convCONSTANTS.BITSCONVERSION_GALVO;
    y_Galvo = double(tdmsData.("Galvo Y Control (bits)")) * convCONSTANTS.BITSCONVERSION_GALVO;
end


x_k = double(tdmsData.("x_k (nm)"));
y_k = double(tdmsData.("y_k (nm)"));
z_k = double(tdmsData.("z_k (nm)"));
stdXYZ = [std(x_k), std(y_k), std(z_k)];

stdRaw = repmat(stdXYZ, nSamples, 1);
timeRaw = (0:(nSamples - 1))' * scriptSettings.activeFeedbackLoopPeriod;

% Decimate the data
combinedData = [intensity x_k y_k trajPosition x_Galvo y_Galvo z_k];
clear tdmsData

scriptSettings.downSamplingFactor = 100; % This bring temporal res to 1ms
scriptSettings.downSamplingEdgeTrim = 100; % This removes the first and last 100 ms of combinedDataFilt

combinedDataFilt = decimateColumns(combinedData, scriptSettings.downSamplingFactor);

combinedDataFilt = combinedDataFilt((scriptSettings.downSamplingEdgeTrim + 1):(end - scriptSettings.downSamplingEdgeTrim), :);

nFiltered = size(combinedDataFilt, 1);
stdFilt = repmat(stdXYZ, nFiltered, 1);

dtFiltered = scriptSettings.activeFeedbackLoopPeriod * scriptSettings.downSamplingFactor;
timeFiltered = (0:(nFiltered - 1))' * dtFiltered;

trackData = [combinedData stdRaw timeRaw];
trackDataFilt = [combinedDataFilt stdFilt timeFiltered];

% Save .mat file for trajectory
matFilePath = fullfile(processedDataSavePath, trajectoryName + ".mat");
if scriptSettings.trajMatIsTable
tableLabels = {'Intensity (counts/s)', 'x_k (nm)', 'y_k (nm)',...
    'Stage X Readout (um)', 'Stage Y Readout (um)', 'Stage Z Readout (um)',...
    'Galvo X Control (um)', 'Galvo Y Control (um)','z_k (nm)', 'x_k std (nm)',...
    'y_k std (nm)', 'z_k std (nm)', 'Time (s)'};

trackDataFiltTable = array2table(trackDataFilt, "VariableNames", tableLabels);
trackDataTable = array2table(trackData, "VariableNames", tableLabels);

save(matFilePath, "trackDataTable", "trackDataFiltTable");

else
save(matFilePath, "trackData", "trackDataFilt");
end

% MSD calculation and plot

[msd3DPlotData, msd1DPlotData, msd1dArr] = calculateMSDXYZ(trackDataFilt, scriptSettings);

% Plot track data
plotTypes  = {'intensity', '3dtraj', 'x_k', 'y_k', 'z_k', 'galvoX', 'galvoY',...
    'stageX', 'stageY', 'stageZ', '3dMSD'};
if scriptSettings.calc1dMSD
    plotTypes = [plotTypes, {'msd1D_x', 'msd1D_y', 'msd1D_z'}];
end
plotSettingsLocal.saveFig = true; 
for i =1:numel(plotTypes)
 plotTrackData(trackDataFilt, msd1DPlotData, msd3DPlotData, plotTypes{i},...
     scriptSettings, plotSettingsLocal);
end

D = msd3DPlotData.D;
r = msd3DPlotData.r_nm;
R2 = msd3DPlotData.R2;

% Make collage
if scriptSettings.makeDataCollage
    createTrajectoryCollage(trackDataFilt, msd3DPlotData, msd1DPlotData, ...
        scriptSettings, plotSettingsLocal);
end

% Update for tracking struct
trackingOut.name = trajectoryName;
trackingOut.meanIntensity = mean(trackDataFilt(:, trackDataColFiltKey('intensity')));
trackingOut.radius = r;
trackingOut.D = D;
trackingOut.msdR2 = R2;
trackingOut.timelength = trajDuration;
trackingOut.std_X_k = stdXYZ(1);
trackingOut.std_Y_k = stdXYZ(2);
trackingOut.std_Z_k = stdXYZ(3);
trackingOut.msd1D = msd1dArr;
end

function trackingOut = emptyTrackingStruct()
%{
Initialize empty structure for tracking struct variable
%}
trackingOut = struct( ...
    'name', "", ...
    'meanIntensity', NaN, ...
    'radius', NaN, ...
    'D', NaN, ...
    'msdR2', NaN, ...
    'timelength', NaN, ...
    'std_X_k', [], ...
    'std_Y_k', [], ...
    'std_Z_k', [], ...
    'msd1D', []);

end

function tdmsData = readTDMSLocalCopy(networkTDMSPath, localTDMSFolder)
%{
Function to
1. Copy .tdms and .tdms_index files from network location to a local folder
2. Read .tdms file to tdmsData
3. Delete the copied files from 1
%}

[~, ~, fileExt] = fileparts(networkTDMSPath);
localTDMSPath = string(tempname(localTDMSFolder)) + string(fileExt);
cleanupObj = onCleanup(@() deleteLocalTDMSFiles(localTDMSPath));

copyfile(networkTDMSPath, localTDMSPath); % Copy .tdms files to local

% Copy .tdms_index files 
networkIndexPath = string(networkTDMSPath) + "_index";
localIndexPath = string(localTDMSPath) + "_index";
if exist(networkIndexPath, 'file')
    copyfile(networkIndexPath, localIndexPath);
end

tdmsDataCell = tdmsread(localTDMSPath);
tdmsData = tdmsDataCell{1};
clear cleanupObj  % Runs deleteLocalTDMSFiles exactly once.

% Nested function for deleting the local copied files
    function deleteLocalTDMSFiles(localTDMSPath)
        localTDMSPath = string(localTDMSPath);
        localIndexPath = localTDMSPath + "_index";

        if exist(localTDMSPath, 'file')
            delete(localTDMSPath);
        end

        if exist(localIndexPath, 'file')
            delete(localIndexPath);
        end
    end
end

function dataOut = decimateColumns(dataIn, factor)
% Apply MATLAB decimate() to each time-varying column.
firstColumn = decimate(dataIn(:, 1), factor);
dataOut = zeros(numel(firstColumn), size(dataIn, 2), 'like', firstColumn);
dataOut(:, 1) = firstColumn;

for columnIndex = 2:size(dataIn, 2)
    filteredColumn = decimate(dataIn(:, columnIndex), factor);
    if numel(filteredColumn) ~= size(dataOut, 1)
        error('decimate returned inconsistent column lengths.');
    end
    dataOut(:, columnIndex) = filteredColumn;
end
end

function applyPlotSettings(ax, plotSettings)
%{
Applies apperance tweaks on the current axes with values from plotSettings
%}
fig = ancestor(ax, 'figure');
[bgColor, textColor] = themeColors(plotSettings.background);

fig.Color = bgColor;
ax.FontSize = plotSettings.fontSize;
ax.Color = bgColor;
ax.XColor = textColor;
ax.YColor = textColor;
ax.ZColor = textColor;
ax.XLabel.Color = textColor;
ax.YLabel.Color = textColor;
ax.ZLabel.Color = textColor;
ax.Title.Color = textColor;
ax.FontSize = plotSettings.fontSize;

if isfield(plotSettings, 'plotGrid') && plotSettings.plotGrid
    grid(ax, 'on');

    if strcmpi(plotSettings.background, 'black')
        ax.GridColor = [0.7 0.7 0.7];
        ax.MinorGridColor = [0.5 0.5 0.5];
    else
        ax.GridColor = [0.2 0.2 0.2];
        ax.MinorGridColor = [0.4 0.4 0.4];
    end

    ax.GridAlpha = 0.35;
    ax.MinorGridAlpha = 0.25;
else
    grid(ax, 'off');
end
end

function applySaveSettings(plotType, plotSettings)
%{
Apply a function to make the .fig file visible when opened later and 
save .fig file to location
%}
fig = gcf;
fig.CreateFcn = 'set(gcbo, ''Visible'', ''on'')';
saveFilePath = fullfile(plotSettings.savePath, string(plotType) + ".fig");
savefig(fig, saveFilePath);
close(fig);
end


function plotTrackData(trackDataFilt, msd1DPlotData, msd3DPlotData,...
    plotType, scriptSettings, plotSettings, ax)
%{
Central plotting function for individual plots
%}
if nargin < 7
    fig = figure('Visible','off');
    ax = axes(fig);
end

switch plotType
    case 'intensity'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'Intensity (counts/s)', plotSettings, plotSettings.title);
    case '3dtraj' 
        if scriptSettings.stageTracking
            x = trackDataFilt(:, trackDataColFiltKey('stageX'));
            y = trackDataFilt(:, trackDataColFiltKey('stageY'));
        else
            x = trackDataFilt(:, trackDataColFiltKey('galvoX'));
            y = trackDataFilt(:, trackDataColFiltKey('galvoY'));
        end
        z = trackDataFilt(:, trackDataColFiltKey('stageZ'));
        time = trackDataFilt(:, trackDataColFiltKey('time'));
        plot3Dtraj(ax, x,y,z,time, plotSettings);
    case 'x_k'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'x_k (nm)', plotSettings, plotSettings.title);
    case 'y_k'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'y_k (nm)', plotSettings, plotSettings.title);
    case 'z_k'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'z_k (nm)', plotSettings, plotSettings.title);
    case 'galvoX'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'Galvo X Control (\mum)', plotSettings, plotSettings.title);
    case 'galvoY'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'Galvo Y Control (\mum)', plotSettings, plotSettings.title);
    case 'stageX'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'Stage X Readout (\mum)', plotSettings, plotSettings.title);
    case 'stageY'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'Stage Y Readout (\mum)', plotSettings, plotSettings.title);
    case 'stageZ'
        plotVersusTime(ax, trackDataFilt, trackDataFilt(:, trackDataColFiltKey(plotType)),...
            'Stage Z Readout (\mum)', plotSettings, plotSettings.title);

    case 'msd1D_x'
        plotMSD(ax, msd1DPlotData(1), plotSettings,plotSettings.title);
    case 'msd1D_y'
        plotMSD(ax, msd1DPlotData(2), plotSettings, plotSettings.title);
    case 'msd1D_z'
        plotMSD(ax, msd1DPlotData(3), plotSettings, plotSettings.title);
    case '3dMSD'
        plotMSD(ax, msd3DPlotData, plotSettings, plotSettings.title);

    otherwise
        error('Invalid plotType.');
end
applyPlotSettings(gca, plotSettings);
if plotSettings.saveFig
    applySaveSettings(plotType, plotSettings);
end
end

function [msd3DPlotData, msd1DPlotData, metrics1D] = ...
    calculateMSDXYZ(trackDataFilt, scriptSettings)
%{
Main function for MSD calculation

1D MSD is calculated via meanSquaredDisplacementFFT()
3D MSD is calculated here
Perform linear fit from MSD data 
Calculate errorbar for the fit via calculateMSDUncertainty()
%}
% Calculate exact mean MSD values in O(N log N) time using autocorrelation.
% The original code repeated an O(N^2) displacement loop for 3D, X, Y,
% and Z. Here all three axes are transformed together and then reused.

time = trackDataFilt(:, trackDataColFiltKey('time'));
xStage = trackDataFilt(:, trackDataColFiltKey('stageX'));
yStage = trackDataFilt(:, trackDataColFiltKey('stageY'));
zStage = trackDataFilt(:, trackDataColFiltKey('stageZ'));
xGalvo = trackDataFilt(:, trackDataColFiltKey('galvoX'));
yGalvo = trackDataFilt(:, trackDataColFiltKey('galvoY'));

if scriptSettings.stageTracking
    msdPosition = [xStage yStage zStage];
else
    msdPosition = [xGalvo yGalvo zStage];
end

nSamples = size(msdPosition, 1);

maxLag = floor(nSamples/4);
maxLag = max(1, min(maxLag, nSamples - 1));
dt = (time(end) - time(1)) / (nSamples - 1);
tauAll = (1:maxLag)' * dt;

msd1DAll = meanSquaredDisplacementFFT(msdPosition, maxLag);
msd3DAll = sum(msd1DAll, 2);

fitDenominator = tauAll' * tauAll;
slope3D = (tauAll' * msd3DAll) / fitDenominator;
diffusion3D = slope3D / 6;
radius3D = diffusionToRadius(diffusion3D);
r2_3D = calcR2(msd3DAll, slope3D * tauAll);

maxMSDPlotPoints = 400; % Max number of MSD points for display
plotLags = selectMSDPlotLags(maxLag, maxMSDPlotPoints);
plotTau = tauAll(plotLags);
[uncertainty3D, uncertainty1D] = calculateMSDUncertainty( ...
    msdPosition, plotLags, scriptSettings.calc1dMSD);

msd3DPlotData = struct( ...
    'tauArr', plotTau, ...
    'msdArr', msd3DAll(plotLags), ...
    'uncertaintyArr', uncertainty3D, ...
    'slope', slope3D, ...
    'D', diffusion3D, ...
    'r_nm', radius3D, ...
    'R2', r2_3D);

msd1DPlotData = repmat(emptyMSDPlotData(), 3, 1);
metrics1D = [];
if scriptSettings.calc1dMSD
    slopes1D = (tauAll' * msd1DAll) / fitDenominator;
    diffusion1D = slopes1D / 2;
    radii1D = diffusionToRadius(diffusion1D);

    r2_1D = zeros(1, 3);
    for dimensionIndex = 1:3
        r2_1D(dimensionIndex) = calcR2( ...
            msd1DAll(:, dimensionIndex), ...
            slopes1D(dimensionIndex) * tauAll);
    end
    for dimensionIndex = 1:3
        if isempty(uncertainty1D)
            dimensionUncertainty = [];
        else
            dimensionUncertainty = uncertainty1D(:, dimensionIndex);
        end

        msd1DPlotData(dimensionIndex) = struct( ...
            'tauArr', plotTau, ...
            'msdArr', msd1DAll(plotLags, dimensionIndex), ...
            'uncertaintyArr', dimensionUncertainty, ...
            'slope', slopes1D(dimensionIndex), ...
            'D', diffusion1D(dimensionIndex), ...
            'r_nm', radii1D(dimensionIndex), ...
            'R2', r2_1D(dimensionIndex));
        metrics1D = [diffusion1D(:), radii1D(:), r2_1D(:)];

    end
end
end

function msd = meanSquaredDisplacementFFT(msdPosition, maxLag)
%{
Function to calculate 1D MSD with some autocorellation
Refer to the README for detailed explanation of this function
%}
nSamples = size(msdPosition, 1);
nFFT = 2 ^ nextpow2((2 * nSamples)); % add zero-padding to prevent FFT from wrapping around

frequencyData = fft(msdPosition, nFFT, 1);
autocorrelation = real(ifft(abs(frequencyData).^2, [], 1));

cumulativeSquares = [zeros(1, size(msdPosition, 2)); ...
    cumsum(msdPosition.^2, 1)];
lags = (1:maxLag)';

sumEarly = cumulativeSquares(nSamples - lags + 1, :);
sumLate = cumulativeSquares(nSamples + 1, :) - ...
    cumulativeSquares(lags + 1, :);
pairCounts = nSamples - lags;

msd = (sumEarly + sumLate - 2 * autocorrelation(lags + 1, :)) ...
    ./ pairCounts;

% Roundoff can produce tiny negative values when the true MSD is zero.
msd = max(msd, 0);
end

function plotLags = selectMSDPlotLags(maxLag, maxPlotPoints)
%{
Function to select subset of MSD points for plotting
This is faster than plotting every single MSD points available.
%}
maxPlotPoints = max(1, round(maxPlotPoints));
if maxLag <= maxPlotPoints
    plotLags = (1:maxLag)';
else
    plotLags = unique(round(logspace(0, log10(maxLag), maxPlotPoints)))';
    if plotLags(end) ~= maxLag
        plotLags(end + 1, 1) = maxLag;
    end
end
end

function [uncertainty3D, uncertainty1D] = ...
    calculateMSDUncertainty(msdPosition, plotLags, calculate1D)
% Calculate errorbar for MSD plots

nPlotLags = numel(plotLags);
uncertainty3D = zeros(nPlotLags, 1);

if calculate1D
    uncertainty1D = zeros(nPlotLags, 3);
else
    uncertainty1D = [];
end

for plotIndex = 1:nPlotLags
    lag = plotLags(plotIndex);
    displacement = msdPosition((lag + 1):end, :) - msdPosition(1:(end - lag), :);
    squaredDisplacement = displacement.^2;
    nPairs = size(squaredDisplacement, 1);

    uncertainty3D(plotIndex) = std(sum(squaredDisplacement, 2)) / sqrt(nPairs);
    if calculate1D
        uncertainty1D(plotIndex, :) = ...
            std(squaredDisplacement, 0, 1) / sqrt(nPairs);
    end
end
end

function r2 = calcR2(observed, fitted)
%{
Calculate R2 for linear MSD fit
%}
residualSumSquares = sum((observed - fitted).^2);
totalSumSquares = sum((observed - mean(observed)).^2);

if totalSumSquares <= eps(max(abs(observed))) * numel(observed)
    r2 = NaN;
else
    r2 = 1 - residualSumSquares / totalSumSquares;
end
end

function radiusNm = diffusionToRadius(diffusionUm2PerS)
%{ 
Calculate the hydrodynamic radius from diffusion coefficient
Units:
 radius = nm
 diffusion coefficient = um^2/s
%}

kB = 1.381e-23;      % J/K
temperature = 293.15; % K
viscosity = 1.005e-3; % Pa*s

radiusNm = nan(size(diffusionUm2PerS));
valid = isfinite(diffusionUm2PerS) & diffusionUm2PerS > 0;
diffusionM2PerS = diffusionUm2PerS(valid) * 1e-12;
radiusNm(valid) = ...
    kB * temperature ./ (6 * pi * viscosity * diffusionM2PerS) * 1e9;
end

function colIdx = trackDataColFiltKey(plotType)
%{
Lookup function to associate the plotType with the column index in
trackDataFilt.
Random note: though one can get better readability if using
trackDataFiltTable (due to table headers), the array form trackDataFilt is
faster for processing.
%}
switch plotType
    case 'intensity'
        colIdx = 1;
    case 'x_k'
        colIdx = 2;
    case 'y_k'
        colIdx = 3;
    case 'stageX'
        colIdx = 4;
    case 'stageY'
        colIdx = 5;
    case 'stageZ'
        colIdx = 6;
    case 'galvoX'
        colIdx = 7;
    case 'galvoY'
        colIdx = 8;
    case 'z_k'
        colIdx = 9;
    case 'x_k std'
        colIdx = 10;
    case 'y_k std'
        colIdx = 11;
    case 'z_k std'
        colIdx = 12;
    case 'time'
        colIdx = 13;
    otherwise
        error('Invalid plot type.');
end
end

function createTrajectoryCollage(trackDataFilt, msd3DPlotData, msd1DPlotData,...
    scriptSettings, plotSettings)
%{
Function to create and plot data collage
%}

% Initialize
plotSettings.collageTiles = defaultCollageTiles(scriptSettings);
[bgColor, titleColor] = themeColors(plotSettings.background);

collageFig = figure('Visible','off', 'Color', bgColor);
collageFig.Units = 'pixels';
collageFig.Position = [100 100 1800 1300];

if scriptSettings.calc1dMSD
    plotSettings.collageRows = 4;
    plotSettings.collageCols = 3;
else
    plotSettings.collageRows = 3;
    plotSettings.collageCols = 3;
end

layout = tiledlayout(collageFig, plotSettings.collageRows, plotSettings.collageCols);
layout.TileSpacing = 'compact';
layout.Padding = 'compact';
sgtitle(layout, plotSettings.title, 'FontSize', plotSettings.fontSize + 4,...
    'FontWeight', 'bold', 'Color', titleColor);

% Change some settings in plotSettings to fit the tile usage
plotSettings.saveFig = false; %so it doesn't save .fig for every tile
plotSettings.fontSize = max(8, plotSettings.fontSize - 4); 
for i = 1:numel(plotSettings.collageTiles)
    tileSpec = plotSettings.collageTiles(i);
    plotSettings.title = tileSpec.plotType;
    ax = nexttile(layout, tileSpec.tile, tileSpec.span);
    plotTrackData(trackDataFilt, msd1DPlotData, msd3DPlotData,...
    tileSpec.plotType, scriptSettings, plotSettings, ax);
end

% Save collage
collageFig.CreateFcn = 'set(gcbo, ''Visible'', ''on'')';
if scriptSettings.saveCollagePNG
    [~, collagePNGName] = fileparts(plotSettings.savePath);
    drawnow limitrate nocallbacks
    exportgraphics(collageFig, ...
        fullfile(plotSettings.savePath, collagePNGName + " collage.png"), ...
        'Resolution', plotSettings.collagePNGResolution, ...
        'BackgroundColor', bgColor);
end

collageFigPath = fullfile(plotSettings.savePath, "collage.fig");
savefig(collageFig, collageFigPath);
close(collageFig);
end

function plotVersusTime(ax, trackDataFilt, y, yLabel, plotSettings, plotTitle)
% Plotting function for any plot where x = trajectory time 
if nargin < 6
    plotTitle = '';
end

time = trackDataFilt(:, trackDataColFiltKey('time'));

yAxData = plot(ax, time, y, ...
    'LineWidth', plotSettings.lineWidth, ...
    'Color', plotSettings.lineColor);

xlabel(ax, 'Time (s)');
ylabel(ax, yLabel);
xlim(ax, [0 time(end)]);
title(ax, plotTitle);

end

function plot3Dtraj(ax, x,y,z, time, plotSettings, plotTitle)
% Plotting function for 3D trajectory
if nargin < 7
    plotTitle = '';
end
% Plot 3D trajectory
x = x(:);
y = y(:);
z = z(:);
time = time(:);
surface(ax, [x x], [y y], [z z], [time time], ...
    'FaceColor', 'none', ...
    'EdgeColor', 'interp', ...
    'LineWidth', plotSettings.lineWidth);
colormap(ax, jet(256))

cb = colorbar(ax);
clim(ax, [0 time(end)])
cb.Ticks = linspace(0, time(end), 6);
cb.TickLabels = compose('%.2f', cb.Ticks);
cb.Label.String = 'Time (s)';
cb.Label.FontSize = plotSettings.fontSize;
cb.Location = 'eastoutside';
[~, textColor] = themeColors(plotSettings.background);
cb.Color = textColor;
cb.Label.Color = textColor;

xlabel(ax, 'X (\mum)')
ylabel(ax, 'Y (\mum)')
zlabel(ax, 'Z (\mum)')
view(ax, 135, 25)
axis equal
title(ax, plotTitle)
end

function plotMSD(ax, msdPlotData, plotSettings, plotTitle)
% Plotting function for MSD

hold(ax, 'on')
plot(ax, msdPlotData.tauArr, msdPlotData.msdArr,...
    'LineWidth', plotSettings.lineWidth+1,...
    'Color', plotSettings.lineColor);

plot(ax, msdPlotData.tauArr, msdPlotData.slope * msdPlotData.tauArr,...
    'LineWidth', plotSettings.lineWidth+1, 'LineStyle', '--',...
    'Color', plotSettings.lineColor); % linear fit

if ~isempty(msdPlotData.uncertaintyArr)
    errorbar(ax, msdPlotData.tauArr, msdPlotData.msdArr, ...
        msdPlotData.uncertaintyArr, 'vertical', ...
        'Color', plotSettings.lineColor, 'LineStyle', 'none');
end

xlabel(ax, '\tau (s)')
ylabel(ax, 'MSD (\mum^2)')
[~, textColor] = themeColors(plotSettings.background);
text(ax, max(msdPlotData.tauArr)*0.2, max(msdPlotData.msdArr)*0.8, ...
    sprintf('D = %.4f um^2/s\nr = %.4f nm\nR2 = %.4f', ...
    msdPlotData.D, msdPlotData.r_nm, msdPlotData.R2), ...
    'FontSize', max(8, plotSettings.fontSize - 4), ...
    'Color', textColor);
title(ax, plotTitle);
end

function [bgColor, textColor] = themeColors(background)
% Function to get background and text color values based on the background
% color
switch lower(background)
    case 'white'
        bgColor = 'w';
        textColor = 'k';
    case 'black'
        bgColor = 'k';
        textColor = 'w';
    otherwise
        error('Invalid background setting. Use "white" or "black".');
end
end

function tiles = defaultCollageTiles(scriptSettings)
%{
Function to setup the collage plot. Structure changes based on the state of
stageTracking and calc1dMSD
%}

% If 1D MSD plot data was calculated
if scriptSettings.calc1dMSD
    if scriptSettings.stageTracking % Stage tracking
        tiles = [
            struct('plotType', 'stageX', 'tile', 1, 'span', [1 1])
            struct('plotType', 'msd1D_x', 'tile', 2, 'span', [1 1])
            struct('plotType', 'intensity', 'tile', 3, 'span', [1 1])
            struct('plotType', 'stageY', 'tile', 4, 'span', [1 1])
            struct('plotType', 'msd1D_y', 'tile', 5, 'span', [1 1])
            struct('plotType', '3dtraj', 'tile', 6, 'span', [2 1])
            struct('plotType', 'stageZ', 'tile', 7, 'span', [1 1])
            struct('plotType', 'msd1D_z', 'tile', 8, 'span', [1 1])
            struct('plotType', '3dMSD', 'tile', 11, 'span', [1 1])
            ];
    else % Galvo tracking
        tiles = [
            struct('plotType', 'galvoX', 'tile', 1, 'span', [1 1])
            struct('plotType', 'msd1D_x', 'tile', 2, 'span', [1 1])
            struct('plotType', 'intensity', 'tile', 3, 'span', [1 1])
            struct('plotType', 'galvoY', 'tile', 4, 'span', [1 1])
            struct('plotType', 'msd1D_y', 'tile', 5, 'span', [1 1])
            struct('plotType', '3dtraj', 'tile', 6, 'span', [2 1])
            struct('plotType', 'stageZ', 'tile', 7, 'span', [1 1])
            struct('plotType', 'msd1D_z', 'tile', 8, 'span', [1 1])
            struct('plotType', '3dMSD', 'tile', 11, 'span', [1 1])
            ];
    end
else % Only 3D MSD plot data is available
    if scriptSettings.stageTracking
        tiles = [
            struct('plotType', 'stageX', 'tile', 1, 'span', [1 1])
            struct('plotType', 'intensity', 'tile', 2, 'span', [1 1])
            struct('plotType', '3dtraj', 'tile', 3, 'span', [2 1])
            struct('plotType', 'stageY', 'tile', 4, 'span', [1 1])
            struct('plotType', '3dMSD', 'tile', 5, 'span', [1 1])
            struct('plotType', 'stageZ', 'tile', 7, 'span', [1 1])
            ];
    else
        tiles = [
            struct('plotType', 'galvoX', 'tile', 1, 'span', [1 1])
            struct('plotType', 'intensity', 'tile', 2, 'span', [1 1])
            struct('plotType', '3dtraj', 'tile', 3, 'span', [2 1])
            struct('plotType', 'galvoY', 'tile', 4, 'span', [1 1])
            struct('plotType', '3dMSD', 'tile', 5, 'span', [1 1])
            struct('plotType', 'stageZ', 'tile', 7, 'span', [1 1])
            ];
    end
end

end

function out = emptyMSDPlotData()
% Initialize struct variable for MSD plot data
out = struct('tauArr', [], 'msdArr', [], 'uncertaintyArr', [], ...
    'slope', NaN, 'D', NaN, 'r_nm', NaN, 'R2', NaN);
end

function notifySlackWhenDone(matlabNotifierID, mainFileName)
%{
Utility code to send a message to Slack once a MATLAB script has finished
running through Yuxin's MATLAB Notifier app.
Modified from Yuxin's sendSlackMessage() base function.

matlabNotifierID is the channel ID specific to each Slack user
%}
if nargin < 2 || isempty(mainFileName)
    activeFile = matlab.desktop.editor.getActiveFilename;

    if ~isempty(activeFile)
        [~, mainFileName, ext] = fileparts(activeFile);
        mainFileName = [mainFileName ext];
    else
        mainFileName = 'untitled.m';
    end
end
pcName = getenv('COMPUTERNAME');
botToken = 'FIXME';
message = sprintf('Code in %s on %s has finished running!', mainFileName, pcName);

data = struct;
data.channel = matlabNotifierID;
data.text = message;

options = weboptions( ...
    'HeaderFields', {'Authorization', ['Bearer ' botToken]}, ...
    'MediaType','application/json');

response = webwrite('https://slack.com/api/chat.postMessage', data, options);

if isfield(response, 'ok') && response.ok
    disp('✅ Notified Slack that code was done！');
else
    disp('❌ Could not send message to Slack！');
    disp(response);
end
end
