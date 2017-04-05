require('nngraph')

--[[ Global attention takes a matrix, a query vector and sum of previous attentions. It
  then computes a parameterized convex combination of the matrix
  based on the input query.


    H_1 H_2 H_3 ... H_n
     q   q   q       q
      |  |   |       |
       \ |   |      /
           .....
         \   |  /
             a

Constructs a unit mapping:
  $$(H_1 .. H_n, q) => (a)$$
  Where H is of `batch x n x dim` and q is of `batch x dim`.

  The full function is  $$\tanh(W_2 [(softmax((W_1 q + b_1) H) H), q] + b_2)$$.

--]]
local GlobalAttentionCoverage, parent = torch.class('onmt.GlobalAttentionCoverage', 'onmt.Network')


function GlobalAttentionCoverage.declareOpts(_)
end

--[[A nn-style module computing attention.

  Parameters:

  * `dim` - dimension of the context vectors.
--]]
function GlobalAttentionCoverage:__init(_, dim)
  parent.__init(self, self:_buildModel(dim))
end

GlobalAttentionCoverage.needAttnSum = 1

function GlobalAttentionCoverage:_buildModel(dim)
  local inputs = {}
  table.insert(inputs, nn.Identity()())
  table.insert(inputs, nn.Identity()())
  table.insert(inputs, nn.Identity()())

  local targetT = nn.Linear(dim, dim, false)(inputs[1]) -- batchL x dim
  local context = inputs[2] -- batchL x sourceL x dim
  local sumAttn = inputs[3] -- batchL x sourceL

  -- Get attention.
  local attn = nn.MM()({context, nn.Replicate(1,3)(targetT)}) -- batchL x sourceL x 1
  attn = nn.Sum(3)(attn)
  local softmaxAttn = nn.SoftMax()
  softmaxAttn.name = 'softmaxAttn'
  attn = softmaxAttn(attn)
  attn = nn.Replicate(1,2)(attn) -- batchL x 1 x sourceL

  -- Apply attention to context.
  local contextCombined = nn.MM()({attn, context}) -- batchL x 1 x dim
  contextCombined = nn.Sum(2)(contextCombined) -- batchL x dim

  sumAttn = nn.Replicate(1,2)(sumAttn) -- batchL x 1 x sourceL
  local sumAttnCombined = nn.MM()({sumAttn, context})
  sumAttnCombined = nn.Sum(2)(sumAttnCombined) -- batchL x dim

  contextCombined = nn.JoinTable(2)({contextCombined, inputs[1], sumAttnCombined}) -- batchL x dim*3
  local contextOutput = nn.Tanh()(nn.Linear(dim*3, dim, false)(contextCombined))

  return nn.gModule(inputs, {contextOutput})
end
