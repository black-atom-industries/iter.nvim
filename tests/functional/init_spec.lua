---@diagnostic disable: undefined-field
describe('iter', function()
    before_each(function()
        package.loaded.iter = nil
    end)

    it('sets defaults and marks setup as done', function()
        ---@type Iter
        local iter = require('iter').setup()

        assert.is_true(iter.did_setup)
        assert.are.equal(false, iter.config.options.preview.wrap)
        assert.are.equal(0.25, iter.config.options.status.height)
    end)

    it('merges valid options without losing defaults', function()
        ---@type Iter
        local iter = require('iter').setup({
            preview = { wrap = true },
            status = { height = 0.5 },
        })

        assert.are.equal(true, iter.config.options.preview.wrap)
        assert.are.equal(0.5, iter.config.options.status.height)
        assert.are.equal(true, iter.config.options.confirmations.discard)
    end)

    it('rejects invalid setup options', function()
        assert.has_error(function()
            ---@diagnostic disable-next-line: assign-type-mismatch
            require('iter').setup({ preview = { wrap = 'yes' } })
        end)

        assert.has_error(function()
            require('iter').setup({ status = { height = 2 } })
        end, 'opts.status.height must be a number between 0 and 1')
    end)
end)
