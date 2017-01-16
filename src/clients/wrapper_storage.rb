# encoding: utf-8

# Module:		wrapper_storage.ycp
#
# Authors:		Ladislav Slezak <lslezak@novell.com>
#
# Purpose:		A wrapper for Storage:: module, required for removing yast2-storage dependency
#
# $Id$
module Yast
  class WrapperStorageClient < Client
    def main
      @func = Convert.to_string(WFM.Args(0))
      @param = []

      # get parameters if available
      if Ops.greater_or_equal(Builtins.size(WFM.Args), 2)
        @param = Convert.to_list(WFM.Args(1))
      end

      @ret = nil

      Builtins.y2milestone(
        "Storage:: wrapper: func: %1, args: %2",
        @func,
        @param
      )

      Yast.import "Storage"

      # call the required function
      case @func
      when "GetTargetChangeTime"
        @ret = Storage.GetTargetChangeTime
      else
        # the required function is not known
        Builtins.y2error("unknown function: %1", @func)
      end

      Builtins.y2milestone("Storage wrapper: result: %1", @ret)

      deep_copy(@ret)
    end
  end
end

Yast::WrapperStorageClient.new.main
