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
        assert.are.equal('stacked', iter.config.options.preview.diff_layout)
        assert.are.equal(0.25, iter.config.options.status.height)
    end)

    it('merges valid options without losing defaults', function()
        ---@type Iter
        local iter = require('iter').setup({
            preview = { wrap = true, diff_layout = 'split' },
            status = { height = 0.5 },
        })

        assert.are.equal(true, iter.config.options.preview.wrap)
        assert.are.equal('split', iter.config.options.preview.diff_layout)
        assert.are.equal(120, iter.config.options.preview.diff_auto_threshold)
        assert.are.equal(0.5, iter.config.options.status.height)
    end)

    it('rejects invalid setup options', function()
        assert.has_error(function()
            require('iter').setup({ preview = { diff_layout = 'wide' } })
        end, "opts.preview.diff_layout must be 'stacked', 'split', or 'auto'")

        assert.has_error(function()
            require('iter').setup({ status = { height = 2 } })
        end, 'opts.status.height must be a number between 0 and 1')
    end)
end)
