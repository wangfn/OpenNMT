require('onmt.init')
require('tds')

local cmd = onmt.utils.ExtendedCmdLine.new('train.lua')

-- First argument define the model type: seq2seq/lm - default is seq2seq.
local modelType = cmd.getArgument(arg, '-model_type') or 'seq2seq'
local modelClass = onmt.ModelSelector(modelType)

-- Options declaration.
local options = {
  {
    '-data', '',
    [[Path to the data package `*-train.t7` generated by the preprocessing step.]],
    {
      valid = onmt.utils.ExtendedCmdLine.fileNullOrExists
    }
  }
}

cmd:setCmdLineOptions(options, 'Data')

onmt.data.SampledDataset.declareOpts(cmd)
onmt.data.DynamicDataRepository.declareOpts(cmd, modelClass)
onmt.data.SampledVocabDataset.declareOpts(cmd)

onmt.Model.declareOpts(cmd)
modelClass.declareOpts(cmd)
onmt.train.Trainer.declareOpts(cmd)
onmt.utils.CrayonLogger.declareOpts(cmd)
onmt.utils.Cuda.declareOpts(cmd)
onmt.utils.Logger.declareOpts(cmd)
onmt.utils.HookManager.declareOpts(cmd)

cmd:text('')
cmd:text('Other options')
cmd:text('')

onmt.utils.Memory.declareOpts(cmd)
onmt.utils.Profiler.declareOpts(cmd)

cmd:option('-seed', 3435, [[Random seed.]], {valid=onmt.utils.ExtendedCmdLine.isUInt()})

-- insert on the fly the option depending if there is a hook selected
onmt.utils.HookManager.updateOpt(arg, cmd)
onmt.data.DynamicDataRepository.expandOpts(cmd, modelClass)

local function loadData(opt, filename)

  local data
  if filename ~= '' then
    _G.logger:info('Loading data from \'%s\'...', filename)

    data = torch.load(filename, 'binary', false)

    -- Check if data type is compatible with the target model.
    onmt.utils.Error.assert(modelClass.dataType(data.dataType),
                      'Data type `%s\' is incompatible with `%s\' models',
                      data.dataType, modelClass.modelName())

  else
    data = onmt.data.DynamicDataRepository.new(opt, modelClass)
  end

  -- Keep backward compatibility.
  data.dataType = data.dataType or 'bitext'

  return data
end

local function updateTensorByDict(tensor, dict, updatedDict)

  local updateTensor = tensor:clone()
  updateTensor:resize(updatedDict:size(), tensor:size(2)):fill(0.00000)
  for i = 1, updatedDict:size() do
    local label = updatedDict.idxToLabel[i]
    local idx = dict.labelToIdx[label]
    -- Copy a word's vector if it exists in the two dictionaries
    if idx ~= nil then
      updateTensor[{ i,{} }] = tensor[{ idx,{} }]
    end
  end

  return updateTensor
end

local function mergeDicts(dicts, mergedDicts)

  for i = 1, dicts.src.words:size() do
    local label = dicts.src.words.idxToLabel[i]
    local idx = mergedDicts.src.words.labelToIdx[label]
    -- add a old word to the end of new dicts
    if idx == nil then
      idx = mergedDicts.src.words:size() + 1
      mergedDicts.src.words.idxToLabel[idx] = label
      mergedDicts.src.words.labelToIdx[label] = idx
    end
  end

  for i = 1, dicts.tgt.words:size() do
    local label = dicts.tgt.words.idxToLabel[i]
    local idx = mergedDicts.tgt.words.labelToIdx[label]
    -- add a old word to the end of new dicts
    if idx == nil then
      idx = mergedDicts.tgt.words:size() + 1
      mergedDicts.tgt.words.idxToLabel[idx] = label
      mergedDicts.tgt.words.labelToIdx[label] = idx
    end
  end

  return mergedDicts
end

local function updateVocab(checkpoint, dicts, opt)

  _G.logger:info('Updating the state by the vocabularies of the new train-set...')

  local encoder = onmt.Factory.loadEncoder(checkpoint.models.encoder)
  local decoder
  if checkpoint.models.decoder then
    decoder = onmt.Factory.loadDecoder(checkpoint.models.decoder)
  end
  encoder:apply(function(m)
      if torch.type(m) == "onmt.WordEmbedding" then
        if m.net.weight:size(1) == checkpoint.dicts.src.words:size() then
          m.net.weight = updateTensorByDict(m.net.weight, checkpoint.dicts.src.words, dicts.src.words)
          m.net.gradWeight = updateTensorByDict(m.net.gradWeight, checkpoint.dicts.src.words, dicts.src.words)
        end
        return
      elseif torch.type(m) == "onmt.FeaturesEmbedding" then
        local tables = m.net:findModules("nn.LookupTable")
        for i = 1, #dicts.src.features do
          if tables[i].weight:size(1) == checkpoint.dicts.src.features[i]:size() then
            tables[i].weight = updateTensorByDict(tables[i].weight, checkpoint.dicts.src.features[i], dicts.src.features[i])
            tables[i].gradWeight = updateTensorByDict(tables[i].gradWeight, checkpoint.dicts.src.features[i], dicts.src.features[i])
          end
        end
        return
      end
  end)

  if decoder then
    decoder:apply(function(m)
        if torch.type(m) == "onmt.WordEmbedding" then
          if m.net.weight:size(1) == checkpoint.dicts.tgt.words:size() then
            m.net.weight = updateTensorByDict(m.net.weight, checkpoint.dicts.tgt.words, dicts.tgt.words)
            m.net.gradWeight = updateTensorByDict(m.net.gradWeight, checkpoint.dicts.tgt.words, dicts.tgt.words)
          end
          return
        elseif torch.type(m) == "onmt.FeaturesEmbedding" then
          local tables = m.net:findModules("nn.LookupTable")
          for i = 1, #dicts.tgt.features do
            if tables[i].weight:size(1) == checkpoint.dicts.tgt.features[i]:size() then
              tables[i].weight = updateTensorByDict(tables[i].weight, checkpoint.dicts.tgt.features[i], dicts.tgt.features[i])
              tables[i].gradWeight = updateTensorByDict(tables[i].gradWeight, checkpoint.dicts.tgt.features[i], dicts.tgt.features[i])
            end
          end
          return
        elseif torch.type(m) == "onmt.Generator" then
          local generator = nn.ConcatTable()
          local sizes = onmt.Factory.getOutputSizes(dicts.tgt)
          for i = 1, #sizes do
              local linear = nn.Linear(opt.rnn_size, sizes[i])
              if i == 1 then
                if m.rindexLinear.weight:size(1) == checkpoint.dicts.tgt.words:size() then
                  linear.weight = updateTensorByDict(m.rindexLinear.weight, checkpoint.dicts.tgt.words, dicts.tgt.words)
                  linear.gradWeight = updateTensorByDict(m.rindexLinear.gradWeight, checkpoint.dicts.tgt.words, dicts.tgt.words)
                end
                m.rindexLinear = linear
              elseif #checkpoint.dicts.tgt.features == #dicts.tgt.features then
                local j = i - 1
                if m.net:get(i):get(1).weight:size(1) == checkpoint.dicts.tgt.features[j]:size() then
                  linear.weight = updateTensorByDict(m.net:get(i):get(1).weight, checkpoint.dicts.tgt.features[j], dicts.tgt.features[j])
                  linear.gradWeight = updateTensorByDict(m.net:get(i):get(1).weight, checkpoint.dicts.tgt.features[j], dicts.tgt.features[j])
                end
              end
              generator:add(nn.Sequential()
                              :add(linear)
                              :add(nn.LogSoftMax()))
          end
          m:set(generator)
          return
        end
    end)
  end
  _G.logger:info(' * Updated source dictionary size: %d', dicts.src.words:size())
  _G.logger:info(' * Updated target dictionary size: %d', dicts.tgt.words:size())
  checkpoint.dicts = dicts

  return checkpoint
end

local function buildDataset(opt, data)
  local trainDataset, validDataset

  if torch.type(data) == "DynamicDataRepository" then
    validDataset = data:getValid()
    trainDataset = data:getTraining()
  else
    if opt.sample > 0 then
       trainDataset = onmt.data.SampledDataset.new(opt, data.train.src, data.train.tgt)
    else
       trainDataset = onmt.data.Dataset.new(data.train.src, data.train.tgt)
    end
    if data.valid then
      validDataset = onmt.data.Dataset.new(data.valid.src, data.valid.tgt)
    end
  end

  local nTrainBatch, batchUsage = trainDataset:setBatchSize(opt.max_batch_size, opt.uneven_batches)

  if validDataset then
    validDataset:setBatchSize(opt.max_batch_size, opt.uneven_batches)
  else
    _G.logger:warning('No validation data')
  end

  if data.dataType ~= 'monotext' then
    local srcVocSize
    local srcFeatSize = '-'
    if data.dicts.src then
      srcVocSize = data.dicts.src.words:size()
      srcFeatSize = #data.dicts.src.features
    else
      srcVocSize = '*'..data.dicts.srcInputSize
    end
    local tgtVocSize
    local tgtFeatSize = '-'
    if data.dicts.tgt then
      tgtVocSize = data.dicts.tgt.words:size()
      tgtFeatSize = #data.dicts.tgt.features
    else
      tgtVocSize = '*'..data.dicts.tgtInputSize
    end
    _G.logger:info(' * vocabulary size: source = %s; target = %s',
                   srcVocSize, tgtVocSize)
    _G.logger:info(' * additional features: source = %s; target = %s',
                   srcFeatSize, tgtFeatSize)
  else
    _G.logger:info(' * vocabulary size: %d', data.dicts.src.words:size())
    _G.logger:info(' * additional features: %d', #data.dicts.src.features)
  end
  _G.logger:info(' * maximum sequence length: source = %d; target = %d',
                 trainDataset.maxSourceLength, trainDataset.maxTargetLength)
  _G.logger:info(' * number of training sentences: %d', #trainDataset.src)
  _G.logger:info(' * number of batches: %d',  nTrainBatch)
  _G.logger:info('   - source sequence lengths: %s', opt.uneven_batches and 'variable' or 'equal')
  _G.logger:info('   - maximum size: %d', opt.max_batch_size)
  _G.logger:info('   - average size: %.2f', trainDataset:instanceCount() / nTrainBatch)
  _G.logger:info('   - capacity: %.2f%%', math.ceil(batchUsage * 1000) / 10)

  return trainDataset, validDataset
end

local function loadModel(opt, dicts)
  local checkpoint
  local paramChanges

  checkpoint, opt, paramChanges = onmt.train.Saver.loadCheckpoint(opt)

  if opt.update_vocab ~= 'none' then
    _G.logger:info(' * new source dictionary size: %d', dicts.src.words:size())
    _G.logger:info(' * new target dictionary size: %d', dicts.tgt.words:size())
    _G.logger:info(' * old source dictionary size: %d', checkpoint.dicts.src.words:size())
    _G.logger:info(' * old target dictionary size: %d', checkpoint.dicts.tgt.words:size())
    if opt.update_vocab == 'merge' then
      _G.logger:info(' * Merging new / old dictionaries...')
      dicts = mergeDicts(checkpoint.dicts, dicts)
    else
      _G.logger:info(' * Replacing old dictionaries by new dictionaries...')
    end
    checkpoint = updateVocab(checkpoint, dicts, opt)
  elseif checkpoint.dicts.src.words:size() ~= dicts.src.words:size() or checkpoint.dicts.tgt.words:size() ~= dicts.tgt.words:size() then
    _G.logger:warning('Dictionary size changed, you may need to activate -update_vocab option')
  end

  cmd:logConfig(opt)

  local model = modelClass.load(opt, checkpoint.models, dicts)

  -- Change parameters dynamically.
  if not onmt.utils.Table.empty(paramChanges) then
    model:changeParameters(paramChanges)
  end

  return model, checkpoint.info
end

local function buildModel(opt, dicts)
  _G.logger:info('Building model...')
  return modelClass.new(opt, dicts)
end

local function main()
  local opt = cmd:parse(arg)

  torch.manualSeed(opt.seed)

  -- Initialize global context.
  _G.logger = onmt.utils.Logger.new(opt.log_file, opt.disable_logs, opt.log_level)
  _G.crayon_logger = onmt.utils.CrayonLogger.new(opt)
  _G.profiler = onmt.utils.Profiler.new(false)

  onmt.utils.Cuda.init(opt)
  onmt.utils.Parallel.init(opt)

  _G.logger:info('Training ' .. modelClass.modelName() .. ' model...')

  -- Loading data package.
  local data = loadData(opt, opt.data)

  -- Record data type in the options, and preprocessing options if present.
  opt.data_type = data.dataType
  opt.preprocess = data.opt

  -- Building training datasets.
  local trainDataset, validDataset = buildDataset(opt, data)

  -- Building the model.
  local model
  local trainStates

  if onmt.train.Saver.checkpointDefined(opt) then
    model, trainStates = loadModel(opt, data.dicts)
  else
    model = buildModel(opt, data.dicts)
  end

  onmt.utils.Cuda.convert(model)

  if opt.sample > 0 then
    trainDataset:checkModel(model)
  end

  -- Start training.
  local trainer = onmt.train.Trainer.new(opt, model, data.dicts, trainDataset:getBatch(1))
  trainer:train(trainDataset, validDataset, trainStates)

  _G.logger:shutDown()
end

main()
