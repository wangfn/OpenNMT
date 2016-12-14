local FeaturesGenerator, parent = torch.class('onmt.FeaturesGenerator', 'nn.Container')

function FeaturesGenerator:__init(rnnSize, outputSize, features)
  parent.__init(self)
  self.net = self:_buildGenerator(rnnSize, outputSize, features)
  self:add(self.net)
end

function FeaturesGenerator:_buildGenerator(rnnSize, outputSize, features)
  local generator = nn.ConcatTable()

  -- Add default generator.
  generator:add(nn.Sequential()
                  :add(onmt.Generator(rnnSize, outputSize))
                  :add(nn.SelectTable(1)))

  -- Add a generator for each target feature.
  for i = 1, #features do
    generator:add(nn.Sequential()
                    :add(nn.Linear(rnnSize, features[i]:size()))
                    :add(nn.LogSoftMax()))
  end

  return generator
end

function FeaturesGenerator:updateOutput(input)
  self.output = self.net:updateOutput(input)
  return self.output
end

function FeaturesGenerator:updateGradInput(input, gradOutput)
  self.gradInput = self.net:updateGradInput(input, gradOutput)
  return self.gradInput
end

function FeaturesGenerator:accGradParameters(input, gradOutput, scale)
  self.net:accGradParameters(input, gradOutput, scale)
end